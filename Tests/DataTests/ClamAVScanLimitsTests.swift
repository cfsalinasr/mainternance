import Foundation
@testable import MainternanceData
import MainternanceDomain
import Testing

/// Audit H2 and M4: files clamscan skipped for its size and scan limits, and folders it could not open, are never
/// counted as scanned files and never let a scan look complete.
@Suite("ClamAV scan limits and unreadable folders")
struct ClamAVScanLimitsTests {
    // MARK: parser

    @Test("a limits-exceeded alert is a skipped file, never a finding")
    func parsesLimitsExceeded() {
        #expect(ClamScanOutputParser.parse("/p/big.dmg: Heuristics.Limits.Exceeded.MaxFileSize FOUND")
            == .tooLarge(path: "/p/big.dmg"))
        #expect(ClamScanOutputParser.parse("/p/a: b.zip: Heuristics.Limits.Exceeded.MaxFiles FOUND")
            == .tooLarge(path: "/p/a: b.zip"))
        #expect(ClamScanOutputParser.parse("/p/old.zip: Heuristics.Limits.Exceeded FOUND")
            == .tooLarge(path: "/p/old.zip"))
        // A real signature stays a finding, even one that merely mentions the word "Limits".
        #expect(ClamScanOutputParser.parse("/p/x: Heuristics.Encrypted.Zip FOUND")
            == .found(path: "/p/x", signature: "Heuristics.Encrypted.Zip"))
        #expect(ClamScanOutputParser.parse("/p/x: Win.Limits.Exceeded FOUND")
            == .found(path: "/p/x", signature: "Win.Limits.Exceeded"))
        #expect(ClamScanOutputParser.parse("Scanning /p/big.dmg: Heuristics.Limits.Exceeded.MaxFileSize FOUND")
            == .ignored)
    }

    @Test("a directory clamscan could not open is a folder, not a file")
    func parsesUnreadableFolder() {
        #expect(ClamScanOutputParser.parse("/p/Library/Safari: Can't open directory.")
            == .unreadableFolder(path: "/p/Library/Safari"))
        #expect(ClamScanOutputParser.parse("relative: Can't open directory.") == .ignored)
    }

    // MARK: scanning

    @Test("clamscan is asked to report every file it skips for its limits")
    func passesAlertExceedsMax() async throws {
        let fixture = try ScannerFixture.replaying([.stdout("/t/a: OK")], status: 0)
        _ = await fixture.run()
        let call = try #require(fixture.runner.recorded.first)
        #expect(call.arguments.contains("--alert-exceeds-max=yes"))
        let separator = try #require(call.arguments.firstIndex(of: "--"))
        let option = try #require(call.arguments.firstIndex(of: "--alert-exceeds-max=yes"))
        #expect(option < separator)
    }

    /// The audit's scenario: a 300 MB installer in Downloads was never read. It must not be counted as scanned,
    /// as a threat, or as an unexplained detection, and the scan is not complete.
    @Test("a file over the size limit is not scanned, not a finding, and the scan is not complete")
    func tooLargeFileMakesScanIncomplete() async throws {
        let fixture = try ScannerFixture.replaying([
            .stdout("/t/a: OK"),
            .stdout("/t/huge.pkg: Heuristics.Limits.Exceeded.MaxFileSize FOUND"),
            .stdout("/t/many.zip: Heuristics.Limits.Exceeded.MaxFiles FOUND"),
            .stdout("/t/b: OK")
        ], status: 1) // clamscan counts an alert as an infection, so it exits 1
        let events = await fixture.run()
        let summary = try #require(events.summary)
        #expect(summary.scanned == 2)
        #expect(summary.tooLarge == 2)
        #expect(summary.findings == 0)
        #expect(summary.unattributedDetections == 0)
        #expect(events.findings.isEmpty)
        #expect(summary.isClean)
        #expect(!summary.isComplete)
    }

    @Test("a too-large file next to a real detection keeps both")
    func tooLargeAndRealFinding() async throws {
        let fixture = try ScannerFixture.replaying([
            .stdout("/t/huge.pkg: Heuristics.Limits.Exceeded.MaxScanSize FOUND"),
            .stdout("/t/e: Win.Test.EICAR_HDB-1 FOUND")
        ], status: 1)
        let events = await fixture.run()
        let summary = try #require(events.summary)
        #expect(summary.findings == 1)
        #expect(summary.tooLarge == 1)
        #expect(events.findings.map(\.signature) == ["Win.Test.EICAR_HDB-1"])
    }

    @Test("exit 1 without any finding or limits alert still says a detection could not be attributed")
    func exitOneWithoutAnyAlertStaysUnattributed() async throws {
        let fixture = try ScannerFixture.replaying([.stdout("/t/a: OK")], status: 1)
        let summary = try #require(await fixture.run().summary)
        #expect(summary.unattributedDetections == 1)
    }

    @Test("the same too-large file reported twice counts once")
    func tooLargeDedupe() async throws {
        let fixture = try ScannerFixture.replaying([
            .stdout("/t/huge.pkg: Heuristics.Limits.Exceeded.MaxFileSize FOUND"),
            .stdout("/t/huge.pkg: Heuristics.Limits.Exceeded.MaxScanSize FOUND")
        ], status: 1)
        #expect(try #require(await fixture.run().summary).tooLarge == 1)
    }

    /// The audit's scenario: without Full Disk Access whole folders are blocked. They are counted as folders.
    @Test("an unreadable folder is counted as a folder, not as one unreadable file")
    func unreadableFolderIsCountedAsFolder() async throws {
        let fixture = try ScannerFixture.replaying([
            .stdout("/t/a: OK"),
            .stdout("/t/Library/Safari: Can't open directory."),
            .stdout("/t/Library/Mail: Can't open directory."),
            .stdout("/t/Library/Mail: Can't open directory.")
        ], status: 2)
        let summary = try #require(await fixture.run().summary)
        #expect(summary.unreadableFolders == 2)
        #expect(summary.unreadable == 0)
        #expect(summary.permissionDenied == 0)
        #expect(summary.scanned == 1)
        #expect(!summary.isComplete)
    }

    // MARK: verify (re-check before quarantine)

    private func verify(_ lines: (String) -> [ProcessLine], status: Int32) async throws -> (VerifyResult, RunCall?) {
        let target = try TempDirectory()
        let path = target.url.appendingPathComponent("target").appendingPathComponent("flagged.exe").path
        let fixture = try ScannerFixture(temp: target, runner: FakeRunner.replaying(lines(path), status: status))
        try Data("x".utf8).write(to: URL(fileURLWithPath: path))
        let result = await fixture.scanner.verifyFinding(path: path)
        return (result, fixture.runner.recorded.first)
    }

    /// The audit's scenario: a flagged file padded past the size limit must not re-check as clean.
    @Test("a re-check that hits a limit fails, it is never clean and never confirmed")
    func verifyTooLargeFails() async throws {
        let (result, call) = try await verify(
            { [.stdout("\($0): Heuristics.Limits.Exceeded.MaxFileSize FOUND")] }, status: 1
        )
        guard case let .failed(message) = result else {
            Issue.record("expected a failure, got \(result)")
            return
        }
        #expect(message.contains("too large"))
        #expect(call?.arguments.contains("--alert-exceeds-max=yes") == true)
    }

    @Test("a re-check with a limit line and an OK line is still not clean")
    func verifyTooLargeBeatsOK() async throws {
        let (result, _) = try await verify(
            { [.stdout("\($0): Heuristics.Limits.Exceeded.MaxScanSize FOUND"), .stdout("\($0): OK")] }, status: 0
        )
        guard case .failed = result else {
            Issue.record("expected a failure, got \(result)")
            return
        }
    }

    @Test("a real detection on re-check is still confirmed")
    func verifyRealDetectionWins() async throws {
        let (result, _) = try await verify(
            { [.stdout("\($0): Win.Test.EICAR_HDB-1 FOUND")] }, status: 1
        )
        #expect(result == .confirmed(signature: "Win.Test.EICAR_HDB-1"))
    }
}
