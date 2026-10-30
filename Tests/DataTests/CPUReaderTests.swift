import MainternanceData
import Synchronization
import Testing

struct CPUReaderTests {
    private func ticks(_ user: UInt64 = 0, _ system: UInt64 = 0, _ idle: UInt64 = 0, _ nice: UInt64 = 0) -> CPUTicks {
        CPUTicks(user: user, system: system, idle: idle, nice: nice)
    }

    /// Reader fed by a scripted sequence of samples.
    private func reader(_ samples: [CPUTicks?]) -> CPUReader {
        let queue = Mutex(samples)
        return CPUReader(read: {
            queue.withLock { $0.isEmpty ? nil : $0.removeFirst() }
        })
    }

    @Test func firstCallIsNilBaseline() {
        let sut = reader([ticks(100, 50, 850)])
        #expect(sut.usage() == nil)
    }

    @Test func secondCallUsesDelta() throws {
        let sut = reader([ticks(100, 0, 900), ticks(200, 0, 1200)])
        #expect(sut.usage() == nil)
        let value = try #require(sut.usage())
        #expect(abs(value - 0.25) < 1e-9)
    }

    @Test func threeCallsUseOnlyLastTwo() throws {
        let sut = reader([ticks(0, 0, 0), ticks(25, 0, 75), ticks(100, 0, 100)])
        #expect(sut.usage() == nil)
        let second = try #require(sut.usage())
        #expect(abs(second - 0.25) < 1e-9)
        let third = try #require(sut.usage())
        #expect(abs(third - 0.75) < 1e-9)
    }

    @Test func failedReadKeepsBaselineAndReturnsNil() throws {
        let sut = reader([ticks(0, 0, 0), nil, ticks(50, 0, 50)])
        #expect(sut.usage() == nil)
        #expect(sut.usage() == nil)
        let value = try #require(sut.usage())
        #expect(abs(value - 0.5) < 1e-9)
    }

    @Test func zeroTotalDeltaIsNil() {
        let same = ticks(10, 20, 30, 40)
        #expect(CPUReader.usage(previous: same, current: same) == nil)
    }

    @Test func counterGoingBackwardsIsNil() {
        let previous = ticks(100, 100, 100, 100)
        #expect(CPUReader.usage(previous: previous, current: ticks(99, 200, 200, 200)) == nil)
        #expect(CPUReader.usage(previous: previous, current: ticks(200, 99, 200, 200)) == nil)
        #expect(CPUReader.usage(previous: previous, current: ticks(200, 200, 99, 200)) == nil)
        #expect(CPUReader.usage(previous: previous, current: ticks(200, 200, 200, 99)) == nil)
    }

    @Test func userSystemAndNiceAllCountAsBusy() throws {
        let value = try #require(CPUReader.usage(previous: ticks(), current: ticks(10, 20, 60, 10)))
        #expect(abs(value - 0.4) < 1e-9)
        let idleOnly = try #require(CPUReader.usage(previous: ticks(), current: ticks(0, 0, 10, 0)))
        #expect(abs(idleOnly) < 1e-9)
        let busyOnly = try #require(CPUReader.usage(previous: ticks(), current: ticks(0, 0, 0, 10)))
        #expect(abs(busyOnly - 1) < 1e-9)
    }

    @Test func hugeValuesDoNotOverflow() throws {
        let big = UInt64.max / 2
        let value = try #require(CPUReader.usage(
            previous: ticks(big, big, big, 0), current: ticks(big + 100, big + 100, big + 200, 0)
        ))
        #expect(abs(value - 0.5) < 1e-9)
        let extreme = try #require(CPUReader.usage(
            previous: ticks(0, 0, 0, 0), current: ticks(UInt64.max, UInt64.max, UInt64.max, UInt64.max)
        ))
        #expect(extreme.isFinite && (0 ... 1).contains(extreme))
    }

    @Test func systemReaderSmoke() {
        let sut = CPUReader()
        #expect(sut.usage() == nil)
        if let value = sut.usage() {
            #expect(value.isFinite && (0 ... 1).contains(value))
        }
    }

    /// A per-call Mach port leak cannot be asserted directly; this exercises the real reader heavily so a
    /// regression toward port exhaustion would surface.
    @Test func systemReaderSurvivesManyCalls() {
        for _ in 0 ..< 2000 {
            let ticks = CPUReader.readSystem()
            #expect(ticks != nil)
        }
        let sut = CPUReader()
        _ = sut.usage()
        for _ in 0 ..< 2000 {
            if let value = sut.usage() {
                #expect(value.isFinite && (0 ... 1).contains(value))
            }
        }
    }
}
