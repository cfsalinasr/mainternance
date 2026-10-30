import Foundation
@testable import MainternanceData
import MainternanceDomain
import Synchronization
import Testing

/// Cancel, quit, single-flight and busy-flag release, driven by controllable fake `clamscan` processes.
/// Every scenario runs inside `within(...)`, so a regression fails the test instead of hanging it.
@Suite("ClamAV scanner control")
struct ClamAVScannerControlTests {
    /// A runner that hands out the given fake processes in order.
    private func fixture(_ scans: [ControlledScan]) throws -> ScannerFixture {
        let next = Mutex(0)
        return try ScannerFixture(runner: FakeRunner { _ in
            let index = next.withLock { current -> Int in
                defer { current += 1 }
                return current
            }
            return scans[min(index, scans.count - 1)].launch()
        })
    }

    private static func drain(_ iterator: inout AsyncStream<ScanEvent>.Iterator) async -> [ScanEvent] {
        var events: [ScanEvent] = []
        while let event = await iterator.next() {
            events.append(event)
        }
        return events
    }

    private static func collect(_ stream: AsyncStream<ScanEvent>) async -> [ScanEvent] {
        var iterator = stream.makeAsyncIterator()
        return await drain(&iterator)
    }

    /// Reads until a found event (inclusive).
    private static func readUntilFound(_ iterator: inout AsyncStream<ScanEvent>.Iterator) async -> [ScanEvent] {
        var events: [ScanEvent] = []
        while let event = await iterator.next() {
            events.append(event)
            if event.isFound {
                break
            }
        }
        return events
    }

    private func bounded<T: Sendable>(_ what: String, _ body: @escaping @Sendable () async -> T) async throws -> T {
        try #require(await within(20, what, body))
    }

    @Test("cancel terminates the process group and finishes with cancelled == true and partial counts")
    func cancel() async throws {
        let scan = ControlledScan()
        let fixture = try fixture([scan])
        let scanner = fixture.scanner
        let target = fixture.target
        let (before, after) = try await bounded("cancel") {
            var iterator = scanner.scan(.custom(target)).makeAsyncIterator()
            scan.send(["/t/a: OK", "/t/b: OK", "/t/c: Permission denied. ERROR", "/t/e: Eicar FOUND"])
            let before = await Self.readUntilFound(&iterator)
            await scanner.cancelScan()
            return await (before, Self.drain(&iterator))
        }
        #expect(before.findings.count == 1)
        #expect(scan.signals.count == 1)
        #expect(scan.signals.first?.group == true)
        let summary = try #require(after.summary)
        #expect(summary.cancelled)
        #expect(summary.scanned == 3)
        #expect(summary.findings == 1)
        #expect(summary.unreadable == 1)
        #expect(summary.permissionDenied == 1)
        #expect(after.failure == nil)
        #expect(after.last == .finished(summary))
        #expect(after.progressCounts.last == 3)
    }

    @Test("a second scan while one runs is refused and the first still completes")
    func secondScanRefused() async throws {
        let scan = ControlledScan()
        let fixture = try fixture([scan])
        let scanner = fixture.scanner
        let target = fixture.target
        let (second, first) = try await bounded("second scan") {
            var iterator = scanner.scan(.custom(target)).makeAsyncIterator()
            let started = await iterator.next()
            let second = await Self.collect(scanner.scan(.custom(target)))
            scan.send(["/t/a: OK", "/t/e: Eicar FOUND"])
            scan.exit(1)
            return await (second, [started].compactMap(\.self) + (Self.drain(&iterator)))
        }
        #expect(second == [.failed(message: "A scan is already running")])
        #expect(scan.launchCount == 1)
        #expect(scan.signals.isEmpty)
        #expect(first.findings.count == 1)
        let summary = try #require(first.summary)
        #expect(summary.scanned == 2)
        #expect(!summary.cancelled)
        #expect(first.failure == nil)
    }

    @Test("the busy flag is released after a failed scan")
    func releasedAfterFailure() async throws {
        let first = ControlledScan()
        let second = ControlledScan()
        let fixture = try fixture([first, second])
        let scanner = fixture.scanner
        let target = fixture.target
        let (failed, retried) = try await bounded("after failure") {
            first.exit(2)
            let failed = await Self.collect(scanner.scan(.custom(target)))
            second.send(["/t/a: OK"])
            second.exit(0)
            return await (failed, Self.collect(scanner.scan(.custom(target))))
        }
        #expect(failed.failure != nil)
        #expect(retried.summary?.scanned == 1)
        #expect(retried.failure == nil)
    }

    @Test("the busy flag is released after a refusal")
    func releasedAfterRefusal() async throws {
        let fixture = try ScannerFixture(tools: ["brew"], runner: FakeRunner.replaying(okLines(1), status: 0))
        #expect(await fixture.run().failure != nil)
        fixture.tools.add(["clamscan", "freshclam"])
        #expect(await fixture.run().summary?.scanned == 1)
    }

    @Test("the busy flag is released after a cancel")
    func releasedAfterCancel() async throws {
        let first = ControlledScan()
        let second = ControlledScan()
        let fixture = try fixture([first, second])
        let scanner = fixture.scanner
        let target = fixture.target
        let (cancelled, next) = try await bounded("after cancel") {
            var iterator = scanner.scan(.custom(target)).makeAsyncIterator()
            first.send(["/t/e: Eicar FOUND"])
            _ = await Self.readUntilFound(&iterator)
            await scanner.cancelScan()
            let cancelled = await Self.drain(&iterator)
            second.send(["/t/a: OK"])
            second.exit(0)
            return await (cancelled, Self.collect(scanner.scan(.custom(target))))
        }
        #expect(cancelled.summary?.cancelled == true)
        #expect(next.summary?.cancelled == false)
        #expect(next.summary?.scanned == 1)
    }

    @Test("a cancel with no scan running does not cancel the next scan")
    func staleCancel() async throws {
        let fixture = try ScannerFixture.replaying(okLines(2), status: 0)
        await fixture.scanner.cancelScan()
        let summary = try #require(await fixture.run().summary)
        #expect(!summary.cancelled)
        #expect(summary.scanned == 2)
    }

    @Test("dropping the consumer terminates the process group and releases the busy flag")
    func droppedConsumer() async throws {
        let first = ControlledScan()
        let second = ControlledScan()
        let fixture = try fixture([first, second])
        let scanner = fixture.scanner
        let target = fixture.target
        try await bounded("drop") {
            do {
                var iterator = scanner.scan(.custom(target)).makeAsyncIterator()
                first.send(["/t/e: Eicar FOUND"])
                _ = await Self.readUntilFound(&iterator)
            }
        }
        #expect(await eventually { first.signals.count == 1 })
        #expect(first.signals.first?.group == true)
        second.send(["/t/a: OK"])
        second.exit(0)
        var accepted: ScanSummary?
        // Poll: a refused attempt is cheap and leaves the running scan alone.
        for _ in 0 ..< 400 where accepted == nil {
            let events = await Self.collect(scanner.scan(.custom(target)))
            accepted = events.summary
            if accepted == nil {
                try await Task.sleep(for: .milliseconds(5))
            }
        }
        #expect(accepted?.scanned == 1)
    }

    @Test("terminateNow before the child starts prevents it from starting")
    func quitBeforeStart() async throws {
        let scan = ControlledScan()
        let fixture = try fixture([scan])
        let scanner = fixture.scanner
        let target = fixture.target
        scanner.terminateNow()
        let events = try await bounded("quit before start") {
            await Self.collect(scanner.scan(.custom(target)))
        }
        #expect(scan.launchCount == 0)
        #expect(fixture.runner.recorded.isEmpty)
        #expect(events.summary == nil)
        #expect(events.failure?.contains("quitting") == true)
        fixture.scanner.terminateNow()
    }

    @Test("terminateNow during a scan kills the process group once and is idempotent")
    func quitDuringScan() async throws {
        let scan = ControlledScan()
        let fixture = try fixture([scan])
        let scanner = fixture.scanner
        let target = fixture.target
        let events = try await bounded("quit") {
            var iterator = scanner.scan(.custom(target)).makeAsyncIterator()
            scan.send(["/t/e: Eicar FOUND"])
            var seen = await Self.readUntilFound(&iterator)
            scanner.terminateNow()
            scanner.terminateNow()
            seen += await Self.drain(&iterator)
            return seen
        }
        #expect(scan.signals.count == 1)
        #expect(scan.signals.first?.signal == SIGKILL)
        #expect(scan.signals.first?.group == true)
        #expect(events.findings.count == 1)
        #expect(events.summary == nil)
        #expect(events.failure != nil)
    }
}
