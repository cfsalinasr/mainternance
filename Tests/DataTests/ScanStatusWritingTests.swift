import Foundation
@testable import MainternanceData
import MainternanceDomain
import Synchronization
import Testing

/// Saving: cheap while a scan reports detections, never behind the logical state, flushed on quit.
@Suite("Scan status writing")
struct ScanStatusWritingTests {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    private func finding(_ index: Int) -> ScanFinding {
        ScanFinding(
            id: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", index)) ?? UUID(),
            path: "/Users/someone/Downloads/file \(index).bin", signature: "Sig", foundAt: start
        )
    }

    private func memory(_ count: Int) -> ScanMemory {
        ScanMemory(findings: (0 ..< count).map { finding($0 + 1) })
    }

    private func file(_ temp: TempDirectory) -> URL {
        temp.url.appendingPathComponent("scan-status.json")
    }

    /// A store whose clock only moves when the test says so and whose timer never fires by itself.
    private typealias Store = ScanStatusStore

    private func store(_ temp: TempDirectory, clock: TestClock = TestClock(), timer: TimerGate? = nil) -> Store {
        ScanStatusStore(
            file: file(temp), now: clock.reading,
            sleep: { duration in
                if let timer {
                    await timer.wait(duration)
                } else {
                    try await Task.sleep(for: .seconds(3600))
                }
            }
        )
    }

    @Test("5,000 detections cause two writes, not 5,000, and the file holds all of them after a flush")
    func coalesced() async throws {
        let temp = try TempDirectory()
        let sut = store(temp)
        let all = (1 ... 5000).map { finding($0) }
        for count in 1 ... 5000 {
            await sut.rememberProgress(ScanMemory(findings: Array(all[..<count])))
        }
        #expect(sut.writeCount == 1) // the first detection was written at once
        sut.flushNow()
        #expect(sut.writeCount == 2)
        let loaded = try #require(await ScanStatusStore(file: file(temp)).load())
        #expect(loaded.findings.count == 5000)
    }

    @Test("the first detection is on disk at once")
    func firstIsImmediate() async throws {
        let temp = try TempDirectory()
        let sut = store(temp)
        await sut.rememberProgress(memory(1))
        #expect(await ScanStatusStore(file: file(temp)).load()?.findings.count == 1)
    }

    @Test("a later detection waits at most a second, and a second later it is written")
    func clockMovesOn() async throws {
        let temp = try TempDirectory()
        let clock = TestClock()
        let sut = store(temp, clock: clock)
        await sut.rememberProgress(memory(1))
        await sut.rememberProgress(memory(2))
        #expect(sut.writeCount == 1)
        #expect(await ScanStatusStore(file: file(temp)).load()?.findings.count == 1)
        clock.advance(1.5)
        await sut.rememberProgress(memory(3))
        #expect(sut.writeCount == 2)
        #expect(await ScanStatusStore(file: file(temp)).load()?.findings.count == 3)
    }

    @Test("the pending detection is written by the timer, without any further event")
    func timerFlushes() async throws {
        let temp = try TempDirectory()
        let gate = TimerGate()
        let sut = store(temp, timer: gate)
        let written = AsyncStream<Int>.makeStream()
        sut.onWrite = { count in written.continuation.yield(count) }
        await sut.rememberProgress(memory(1))
        await sut.rememberProgress(memory(2))
        #expect(await gate.waitUntilArmed())
        await gate.fire()
        var seen = 0
        for await count in written.stream {
            seen = count
            if count >= 2 {
                break
            }
        }
        #expect(seen == 2)
        #expect(await ScanStatusStore(file: file(temp)).load()?.findings.count == 2)
    }

    @Test("an ordinary remember or a recorded scan writes at once and takes the pending detections with it")
    func immediateWritesAbsorbPending() async throws {
        let temp = try TempDirectory()
        let sut = store(temp)
        await sut.rememberProgress(memory(1))
        await sut.rememberProgress(memory(2))
        await sut.remember(memory(3))
        #expect(sut.writeCount == 2)
        sut.flushNow()
        #expect(sut.writeCount == 2) // nothing was pending any more
        #expect(await ScanStatusStore(file: file(temp)).load()?.findings.count == 3)
    }

    @Test("the file is decoded once, not once per save")
    func decodedOnce() async throws {
        let temp = try TempDirectory()
        let sut = store(temp)
        for count in 1 ... 50 {
            await sut.remember(memory(count))
            _ = await sut.load()
        }
        #expect(sut.readCount == 1)
    }

    @Test("load answers with the state that is still waiting to be written")
    func loadSeesPending() async throws {
        let temp = try TempDirectory()
        let sut = store(temp)
        await sut.rememberProgress(memory(1))
        await sut.rememberProgress(memory(2))
        #expect(await sut.load()?.findings.count == 2)
    }

    @Test("many saves racing each other never leave an older snapshot on disk")
    func serialised() async throws {
        let temp = try TempDirectory()
        let sut = store(temp)
        await withTaskGroup(of: Void.self) { group in
            for count in 1 ... 60 {
                group.addTask {
                    if count.isMultiple(of: 2) {
                        await sut.remember(memory(count))
                    } else {
                        await sut.rememberProgress(memory(count))
                    }
                }
            }
        }
        sut.flushNow()
        let logical = await sut.load()
        let onDisk = await ScanStatusStore(file: file(temp)).load()
        #expect(logical != nil)
        #expect(logical == onDisk)
    }

    @Test("the quit hook of the scanner services flushes pending detections to disk")
    func quitHookFlushes() async throws {
        let temp = try TempDirectory()
        let paths = ClamAVPaths(supportDirectory: temp.url.appendingPathComponent("support"))
        let services = ScannerServices(
            paths: paths, locator: FakeTools([]).locator, home: temp.url, statusNow: TestClock().reading
        )
        await services.statusStore.rememberProgress(memory(1))
        await services.statusStore.rememberProgress(memory(4))
        let outside = ScanStatusStore(file: ScanStatusStore.defaultFile(paths: paths))
        #expect(await outside.load()?.findings.count == 1)
        services.terminateNow()
        #expect(await ScanStatusStore(file: ScanStatusStore.defaultFile(paths: paths)).load()?.findings.count == 4)
    }

    @Test("after the quit flush, a late detection is written at once instead of waiting for a timer")
    func afterQuitFlushWritesAreImmediate() async throws {
        let temp = try TempDirectory()
        let sut = store(temp) // its timer never fires by itself, like a timer after quit
        await sut.rememberProgress(memory(1))
        sut.flushNow()
        await sut.rememberProgress(memory(2))
        await sut.rememberProgress(memory(3))
        #expect(sut.writeCount == 3)
        #expect(await ScanStatusStore(file: file(temp)).load()?.findings.count == 3)
    }

    @Test("a write that failed stays pending and the next flush writes it")
    func failedWriteStaysPending() async throws {
        let temp = try TempDirectory()
        let blocker = temp.url.appendingPathComponent("support")
        try Data("not a folder".utf8).write(to: blocker) // the store's folder cannot be created: writes fail
        let target = blocker.appendingPathComponent("scan-status.json")
        let sut = ScanStatusStore(file: target, now: TestClock().reading, sleep: { _ in
            try await Task.sleep(for: .seconds(3600))
        })
        await sut.remember(memory(2))
        #expect(sut.writeCount == 0)
        try FileManager.default.removeItem(at: blocker)
        sut.flushNow()
        #expect(sut.writeCount == 1)
        #expect(await ScanStatusStore(file: target).load()?.findings.count == 2)
    }
}

/// Lets a test hold the store's one-second timer and fire it by hand.
actor TimerGate {
    private var armed: CheckedContinuation<Void, Never>?
    private var release: CheckedContinuation<Void, Never>?
    private var isArmed = false

    func wait(_: Duration) async {
        isArmed = true
        armed?.resume()
        armed = nil
        await withCheckedContinuation { release = $0 }
    }

    func waitUntilArmed() async -> Bool {
        if !isArmed {
            await withCheckedContinuation { armed = $0 }
        }
        return true
    }

    func fire() {
        release?.resume()
        release = nil
    }
}
