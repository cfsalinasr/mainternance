import Foundation
@testable import MainternanceData
import Testing

/// Output shapes checked against a real clamscan 1.5.4 run (2026-11-08).
struct ClamAVRealOutputTests {
    /// Captured from a real clamscan 1.5.4 run over one EICAR file and one file over --max-filesize.
    @Test("real clamscan output: a detection next to a too-large file is one finding, nothing unattributed")
    func realMixedRun() async throws {
        let fixture = try ScannerFixture.replaying([
            .stdout("Scanning /t/big.txt"),
            .stdout("/t/big.txt: Heuristics.Limits.Exceeded.MaxFileSize FOUND"),
            .stdout("/t/big.txt: Virus(es) detected ERROR"),
            .stdout("Scanning /t/sub/eicar.com"),
            .stdout("/t/sub/eicar.com: Eicar-Test-Signature FOUND"),
            .stdout("Scanning /t/clean.txt"),
            .stdout("/t/clean.txt: OK"),
            .stdout(""),
            .stdout("----------- SCAN SUMMARY -----------"),
            .stdout("Infected files: 1"),
            .stdout("Total errors: 1")
        ], status: 1)
        let events = await fixture.run()
        let summary = try #require(events.summary)
        #expect(summary.findings == 1)
        #expect(summary.tooLarge == 1)
        #expect(summary.unattributedDetections == 0)
        #expect(!summary.isClean)
    }

    @Test("a real too-large alert cannot offset a lost detection: clamscan's total counts only real detections")
    func realTooLargeCannotHideADetection() async throws {
        let fixture = try ScannerFixture.replaying([
            .stdout("/t/decoy.zip: Heuristics.Limits.Exceeded.MaxFileSize FOUND"),
            .stdout("/t/decoy.zip: Virus(es) detected ERROR"),
            .stdout("Infected files: 1")
        ], status: 1)
        let summary = try #require(await fixture.run().summary)
        #expect(summary.findings == 0)
        #expect(summary.unattributedDetections >= 1)
        #expect(!summary.isClean)
    }
}
