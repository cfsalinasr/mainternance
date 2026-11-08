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
        // A FOUND line is never ignored, even behind a `Scanning ` prefix: it is a detection.
        #expect(ClamScanOutputParser.parse("Scanning /p/big.dmg: Heuristics.Limits.Exceeded.MaxFileSize FOUND")
            == .found(path: "Scanning /p/big.dmg", signature: "Heuristics.Limits.Exceeded.MaxFileSize"))
    }

    @Test("a FOUND line without a usable path is still a detection, never ignored and never too large")
    func foundWithoutPathIsADetection() {
        #expect(ClamScanOutputParser.parse(": Win.Trojan.X FOUND") == .found(path: "", signature: "Win.Trojan.X"))
        #expect(ClamScanOutputParser.parse(": Heuristics.Limits.Exceeded.MaxFileSize FOUND")
            == .found(path: "", signature: "Heuristics.Limits.Exceeded.MaxFileSize"))
        #expect(ClamScanOutputParser.parse("x.pkg: Heuristics.Limits.Exceeded FOUND")
            == .found(path: "x.pkg", signature: "Heuristics.Limits.Exceeded"))
        #expect(ClamScanOutputParser.parse(" FOUND") == .ignored)
    }

    @Test("clamscan's infected-files total is read; other summary lines are ignored")
    func parsesInfectedTotal() {
        #expect(ClamScanOutputParser.parse("Infected files: 2") == .infectedTotal(2))
        #expect(ClamScanOutputParser.parse("Infected files: 0") == .infectedTotal(0))
        #expect(ClamScanOutputParser.parse("Infected files: two") == .ignored)
        #expect(ClamScanOutputParser.parse("Infected files: -1") == .ignored)
        #expect(ClamScanOutputParser.parse("Scanned files: 10") == .ignored)
        #expect(ClamScanOutputParser.parse("----------- SCAN SUMMARY -----------") == .ignored)
    }

    @Test("a directory clamscan could not open is a folder, not a file")
    func parsesUnreadableFolder() {
        #expect(ClamScanOutputParser.parse("/p/Library/Safari: Can't open directory.")
            == .unreadableFolder(path: "/p/Library/Safari"))
        #expect(ClamScanOutputParser.parse("relative: Can't open directory.") == .ignored)
    }

    // MARK: scanning

    @Test("clamscan is asked to report every file it skips for its limits, and to print its own summary")
    func passesAlertExceedsMax() async throws {
        let fixture = try ScannerFixture.replaying([.stdout("/t/a: OK")], status: 0)
        _ = await fixture.run()
        let call = try #require(fixture.runner.recorded.first)
        #expect(call.arguments.contains("--alert-exceeds-max=yes"))
        #expect(!call.arguments.contains("--no-summary"))
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
            .stdout("/t/huge.pkg: Virus(es) detected ERROR"),
            .stdout("/t/many.zip: Heuristics.Limits.Exceeded.MaxFiles FOUND"),
            .stdout("/t/many.zip: Virus(es) detected ERROR"),
            .stdout("/t/b: OK"),
            .stdout("----------- SCAN SUMMARY -----------"),
            .stdout("Infected files: 0"),
            .stdout("Total errors: 2")
        ], status: 2) // real ClamAV 1.5.4: an alert is an error, not an infection; only alerts means exit 2
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

    // MARK: a too-large file never hides a detection (review round 1)

    /// A file named `payload` + newline splits its FOUND line; the half without a path is still a detection.
    @Test("a detection whose line lost its path is counted even next to a too-large file")
    func lostPathNextToTooLarge() async throws {
        let fixture = try ScannerFixture.replaying([
            .stdout("/t/huge.pkg: Heuristics.Limits.Exceeded.MaxFileSize FOUND"),
            .stdout("/t/payload"),
            .stdout(": Win.Trojan.X FOUND")
        ], status: 1)
        let summary = try #require(await fixture.run().summary)
        #expect(summary.unattributedDetections >= 1)
        #expect(!summary.isClean)
    }

    @Test("a forged too-large alert cannot hide a detection whose line starts with Scanning")
    func forgedAlertCannotHideScanningPrefixedDetection() async throws {
        // A malware file named "a\n/t/decoy.zip: Heuristics.Limits.Exceeded FOUND\nScanning z: Sig" prints three lines.
        let fixture = try ScannerFixture.replaying([
            .stdout("/t/a"),
            .stdout("/t/decoy.zip: Heuristics.Limits.Exceeded FOUND"),
            .stdout("Scanning z: Sig FOUND"),
            .stdout("Infected files: 1")
        ], status: 1)
        let summary = try #require(await fixture.run().summary)
        #expect(summary.unattributedDetections >= 1)
        #expect(!summary.isClean)
    }

    @Test("an alert for a path that is not a regular file is dropped and cannot explain a detection")
    func forgedTooLargeForMissingPath() async throws {
        let fixture = try ScannerFixture.replaying([
            .stdout("/t/missing.pkg: Heuristics.Limits.Exceeded FOUND"),
            .stdout("Infected files: 2")
        ], status: 1, isRegularFile: { !$0.hasSuffix("/missing.pkg") })
        let summary = try #require(await fixture.run().summary)
        #expect(summary.tooLarge == 0)
        #expect(summary.unattributedDetections >= 1)
    }

    @Test("clamscan's total above what was attributed is unattributed detections")
    func totalAboveAttributed() async throws {
        // One real detection's line vanished entirely; clamscan still counted it.
        let fixture = try ScannerFixture.replaying([
            .stdout("/t/huge.pkg: Heuristics.Limits.Exceeded.MaxFileSize FOUND"),
            .stdout("/t/e: Win.Test.EICAR_HDB-1 FOUND"),
            .stdout("Infected files: 2")
        ], status: 1)
        let summary = try #require(await fixture.run().summary)
        #expect(summary.unattributedDetections == 1)
        #expect(summary.findings == 1)
        #expect(summary.tooLarge == 1)
    }

    @Test("when the total matches, nothing is unattributed")
    func totalMatches() async throws {
        let fixture = try ScannerFixture.replaying([
            .stdout("/t/huge.pkg: Heuristics.Limits.Exceeded.MaxFileSize FOUND"),
            .stdout("/t/e: Win.Test.EICAR_HDB-1 FOUND"),
            .stdout("Infected files: 1")
        ], status: 1)
        #expect(try #require(await fixture.run().summary).unattributedDetections == 0)
    }

    @Test("only the last total counts: a forged earlier line cannot lower it, and stderr is never read for it")
    func lastTotalWins() async throws {
        let fixture = try ScannerFixture.replaying([
            .stdout("Infected files: 0"),
            .stdout("/t/huge.pkg: Heuristics.Limits.Exceeded.MaxFileSize FOUND"),
            .stdout("Infected files: 2"),
            .stderr("Infected files: 1")
        ], status: 1)
        #expect(try #require(await fixture.run().summary).unattributedDetections == 2)
    }

    @Test("without clamscan's total, exit 1 with no finding is never explained by a too-large file")
    func missingTotalFailsClosed() async throws {
        let fixture = try ScannerFixture.replaying([
            .stdout("/t/huge.pkg: Heuristics.Limits.Exceeded.MaxFileSize FOUND")
        ], status: 1)
        let summary = try #require(await fixture.run().summary)
        #expect(summary.unattributedDetections == 1)
        #expect(summary.tooLarge == 1)
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
