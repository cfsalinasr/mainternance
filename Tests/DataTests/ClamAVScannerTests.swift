import Foundation
@testable import MainternanceData
import MainternanceDomain
import Testing

@Suite("ClamAV scanner")
struct ClamAVScannerTests {
    // MARK: argv and hostile names

    @Test("runs exactly clamscan with the database, flags, a -- separator and the roots; no --infected")
    func exactArguments() async throws {
        let fixture = try ScannerFixture.replaying(okLines(1), status: 0)
        _ = await fixture.run()
        let call = try #require(fixture.runner.recorded.first)
        let root = URL(fileURLWithPath: fixture.target.path).standardizedFileURL.path
        #expect(call.executable == "/fake/bin/clamscan")
        #expect(call.arguments == [
            "--database=\(fixture.paths.databaseDirectory.path)", "-v", "--no-summary", "--recursive", "--", root
        ])
        #expect(!call.arguments.contains("--infected"))
        #expect(call.lowPriority)
        #expect(call.environment == nil)
        #expect(fixture.runner.recorded.count == 1)
    }

    @Test("hostile folder names are passed verbatim after --", arguments: [
        "plain folder", "it's \"quoted\"", "semi;colon", "$(touch pwned)", "-rf $(x) ; y", "-- --infected",
        "line\nbreak", "back`tick`", "star*glob?"
    ])
    func hostileNames(name: String) async throws {
        let fixture = try ScannerFixture.replaying(okLines(1), status: 0)
        let folder = fixture.temp.url.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        _ = await fixture.run(.custom(folder))
        let call = try #require(fixture.runner.recorded.first)
        let separator = try #require(call.arguments.firstIndex(of: "--"))
        let roots = Array(call.arguments[(separator + 1)...])
        #expect(roots.count == 1)
        let root = try #require(roots.first)
        #expect(root.hasPrefix("/"))
        #expect(root.hasSuffix("/" + name))
        // Nothing before the separator mentions the folder.
        #expect(!call.arguments[..<separator].contains { $0.contains(name) })
    }

    @Test("quick scan passes only existing roots")
    func quickRoots() async throws {
        let fixture = try ScannerFixture.replaying(okLines(1), status: 0)
        let downloads = fixture.temp.url.appendingPathComponent("Downloads", isDirectory: true)
        try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
        _ = await fixture.run(.quick)
        let args = try #require(fixture.runner.recorded.first).arguments
        let roots = try Array(args[(#require(args.firstIndex(of: "--")) + 1)...])
        #expect(roots.contains(downloads.standardizedFileURL.path))
        #expect(!roots.contains(fixture.temp.url.appendingPathComponent("Desktop").standardizedFileURL.path))
        #expect(!roots.contains("/"))
    }

    @Test("a custom folder that does not exist fails without a process")
    func missingFolder() async throws {
        let fixture = try ScannerFixture.replaying([], status: 0)
        let events = await fixture.run(.custom(fixture.temp.url.appendingPathComponent("gone")))
        #expect(events.failure?.contains("nothing to scan") == true)
        #expect(fixture.runner.recorded.isEmpty)
    }

    // MARK: events

    @Test("events: started, progress, found, final progress, finished; findings carry path and signature")
    func eventOrder() async throws {
        let fixture = try ScannerFixture.replaying([
            .stdout("/t/a: OK"),
            .stdout("/t/dir: with colon/eicar.txt: Win.Test.EICAR_HDB-1 FOUND"),
            .stdout("/t/b: OK")
        ], status: 1)
        let events = await fixture.run()
        #expect(events.first == .started(scope: .custom(fixture.target)))
        let finding = try #require(events.findings.first)
        #expect(events.findings.count == 1)
        #expect(finding.path == fixture.path("dir: with colon/eicar.txt"))
        #expect(finding.signature == "Win.Test.EICAR_HDB-1")
        let summary = try #require(events.summary)
        #expect(summary.scanned == 3)
        #expect(summary.findings == 1)
        #expect(!summary.cancelled)
        #expect(events.last == .finished(summary))
        #expect(events.progressCounts.last == 3)
        let foundIndex = try #require(events.indices.first { events[$0].isFound })
        let firstProgress = try #require(events.indices.first { events[$0].isProgress })
        #expect(firstProgress < foundIndex)
    }

    @Test("a clean scan finishes with zero findings")
    func cleanScan() async throws {
        let fixture = try ScannerFixture.replaying(okLines(5), status: 0)
        let summary = try #require(await fixture.run().summary)
        #expect(summary.scanned == 5)
        #expect(summary.findings == 0)
        #expect(summary.unreadable == 0)
        #expect(summary.permissionDenied == 0)
    }

    @Test("scope, times and the definitions date come from the injected clock and the database")
    func summaryFields() async throws {
        let clock = TestClock(step: 1)
        let fixture = try ScannerFixture.replaying(okLines(2), status: 0, clock: clock)
        let events = await fixture.run(.custom(fixture.target))
        let summary = try #require(events.summary)
        #expect(summary.scope == .custom(fixture.target))
        #expect(summary.endedAt > summary.startedAt)
        let expectedDate = try #require(DefinitionsStore(paths: fixture.paths).definitionsDate())
        #expect(summary.definitionsDate == expectedDate)
        #expect(expectedDate < summary.startedAt)
    }

    // MARK: permission awareness

    @Test("unreadable files are counted, permission denials separately, and never counted as scanned")
    func unreadableCounts() async throws {
        let fixture = try ScannerFixture.replaying([
            .stdout("/t/a: OK"),
            .stdout("/t/Library/Mail: Operation not permitted. ERROR"),
            .stdout("/t/secret: Permission denied. ERROR"),
            .stdout("/t/dir: Can't open file or directory ERROR"),
            .stdout("/t/broken: Can't parse the thing ERROR"),
            .stdout("/t/b: OK")
        ], status: 2)
        let events = await fixture.run()
        let summary = try #require(events.summary)
        #expect(summary.scanned == 2)
        #expect(summary.unreadable == 4)
        #expect(summary.permissionDenied == 3)
        #expect(summary.findings == 0)
        #expect(events.failure == nil)
    }

    // MARK: exit codes

    @Test("exit 1 means infected files were found, not an error")
    func exitOne() async throws {
        let fixture = try ScannerFixture.replaying([.stdout("/t/e: Eicar FOUND")], status: 1)
        let events = await fixture.run()
        #expect(events.summary?.findings == 1)
        #expect(events.failure == nil)
    }

    @Test("exit 2 without findings or readable errors fails with the last stderr line")
    func exitTwoFails() async throws {
        let fixture = try ScannerFixture.replaying([
            .stdout("/t/a: OK"),
            .stderr("ERROR: cl_load(): Can't open file\u{1B}[31m daily.cvd")
        ], status: 2)
        let events = await fixture.run()
        let message = try #require(events.failure)
        #expect(message.contains("exit 2"))
        #expect(message.contains("daily.cvd"))
        #expect(!message.contains("\u{1B}"))
        #expect(events.summary == nil)
    }

    @Test("exit 2 with findings delivers the findings first, then fails")
    func exitTwoWithFindings() async throws {
        let fixture = try ScannerFixture.replaying([
            .stdout("/t/e: Eicar FOUND"), .stderr("ERROR: Can't allocate memory")
        ], status: 2)
        let events = await fixture.run()
        #expect(events.findings.map(\.path) == [fixture.path("e")])
        let message = try #require(events.failure)
        #expect(message.contains("1 finding"))
        #expect(message.contains("allocate memory"))
        #expect(events.summary == nil)
        let found = try #require(events.indices.first { events[$0].isFound })
        let failed = try #require(events.indices.first { events[$0].isFailure })
        #expect(found < failed)
    }

    @Test("exit 2 with per-file read errors and scanned files is a finished scan (no Full Disk Access)")
    func exitTwoUnreadableOnly() async throws {
        let fixture = try ScannerFixture.replaying(
            okLines(3) + [.stdout("/t/x: Operation not permitted. ERROR")], status: 2
        )
        let summary = try #require(await fixture.run().summary)
        #expect(summary.unreadable == 1)
        #expect(summary.permissionDenied == 1)
        #expect(summary.scanned == 3)
    }

    @Test("exit 2 where nothing was scanned fails even with read errors")
    func exitTwoNothingScanned() async throws {
        let fixture = try ScannerFixture.replaying([.stdout("/t/x: Permission denied. ERROR")], status: 2)
        let events = await fixture.run()
        #expect(events.failure != nil)
        #expect(events.summary == nil)
    }

    @Test("other non-zero exits fail", arguments: [Int32(3), 127, 137, 143])
    func otherExits(status: Int32) async throws {
        let fixture = try ScannerFixture.replaying(okLines(2), status: status)
        let events = await fixture.run()
        #expect(events.failure?.contains("exit \(status)") == true)
        #expect(events.summary == nil)
    }

    @Test("the failure message is bounded")
    func boundedMessage() async throws {
        let fixture = try ScannerFixture.replaying(
            [.stderr("ERROR: " + String(repeating: "x", count: 5000))],
            status: 2
        )
        let message = try #require(await fixture.run().failure)
        #expect(message.count < 400)
    }

    // MARK: volume and throttling

    @Test("100,000 lines: every FOUND is delivered, progress is throttled, the final progress is exact")
    func hugeTranscript() async throws {
        var lines = okLines(100_000)
        for index in stride(from: 0, to: 100_000, by: 1000) {
            lines[index] = .stdout("/t/f\(index): Sig.\(index) FOUND")
        }
        let still = try ScannerFixture.replaying(lines, status: 1)
        let events = await still.run()
        #expect(events.findings.count == 100)
        #expect(events.findings.map(\.signature) == (0 ..< 100).map { "Sig.\($0 * 1000)" })
        #expect(events.progressCounts == [1, 100_000])
        #expect(events.summary?.scanned == 100_000)
        #expect(events.summary?.findings == 100)

        // A ticking clock (1 ms per read) lets some progress through, still far fewer than one per line.
        let ticking = try ScannerFixture.replaying(lines, status: 1, clock: TestClock(step: 0.001))
        let tickEvents = await ticking.run()
        #expect(tickEvents.progressCounts.count > 2)
        #expect(tickEvents.progressCounts.count < 3000)
        #expect(tickEvents.progressCounts == tickEvents.progressCounts.sorted())
        #expect(tickEvents.progressCounts.last == 100_000)
        #expect(tickEvents.findings.count == 100)
    }

    @Test("tally throttles to the interval and always allows a closing progress")
    func tallyThrottle() {
        var tally = ScanTally()
        let start = Date(timeIntervalSince1970: 1000)
        _ = tally.consume(.scanned(path: "/a"))
        #expect(tally.throttledProgress(now: start, interval: 0.1) == .progress(scanned: 1, current: "/a"))
        _ = tally.consume(.scanned(path: "/b"))
        #expect(tally.throttledProgress(now: start.addingTimeInterval(0.05), interval: 0.1) == nil)
        #expect(tally.throttledProgress(now: start.addingTimeInterval(0.1), interval: 0.1)
            == .progress(scanned: 2, current: "/b"))
        #expect(tally.throttledProgress(now: start.addingTimeInterval(5), interval: 0.1) == nil)
        _ = tally.consume(.scanned(path: "/c"))
        #expect(tally.finalProgress(now: start) == .progress(scanned: 3, current: "/c"))
        #expect(tally.finalProgress(now: start) == nil)
    }
}
