import Foundation
@testable import MainternanceData
import MainternanceDomain
import Testing

/// Transcripts built from the formats upstream clamscan really prints (see ClamScanOutputParser).
@Suite("ClamAV scanner failure forms")
struct ClamAVScannerFailureFormsTests {
    // MARK: real clamscan failure forms (upstream manager.c / output.c)

    @Test("a no-Full-Disk-Access style run: warnings on stderr, directories, access denied, one finding")
    func noFullDiskAccessRun() async throws {
        let fixture = try ScannerFixture.replaying([
            .stdout("Scanning /t/a"), .stdout("/t/a: OK"),
            .stderr("WARNING: Can't open file /t/Library/Mail/mbox: Operation not permitted"),
            .stdout("/t/Library/Safari: Can't open directory."),
            .stdout("/t/private.txt: Access denied"),
            .stdout("Scanning /t/e"), .stdout("/t/e: Win.Test.EICAR_HDB-1 FOUND"),
            .stdout("/t/b: OK")
        ], status: 1)
        let events = await fixture.run()
        let summary = try #require(events.summary)
        #expect(summary.scanned == 3)
        #expect(summary.unreadable == 3)
        #expect(summary.permissionDenied == 3)
        #expect(summary.findings == 1)
        #expect(events.failure == nil)
    }

    @Test("the same run without a finding exits 2 and is a finished, partial scan")
    func noFullDiskAccessExitTwo() async throws {
        let fixture = try ScannerFixture.replaying([
            .stdout("/t/a: OK"),
            .stderr("WARNING: Can't open file /t/Library/Mail/mbox: Permission denied"),
            .stdout("/t/Library/Safari: Can't open directory."),
            .stdout("/t/gone: Can't parse ERROR"),
            .stdout("/t/b: OK")
        ], status: 2)
        let summary = try #require(await fixture.run().summary)
        #expect(summary.scanned == 2)
        #expect(summary.unreadable == 3)
        #expect(summary.permissionDenied == 2)
    }

    @Test("one path reported in two forms is counted once")
    func dedupeByPath() async throws {
        let fixture = try ScannerFixture.replaying([
            .stdout("/t/a: OK"),
            .stderr("WARNING: Can't open file /t/x: Permission denied"),
            .stdout("/t/x: Access denied"),
            .stdout("/t/x: Can't open file or directory ERROR")
        ], status: 2)
        let summary = try #require(await fixture.run().summary)
        #expect(summary.unreadable == 1)
        #expect(summary.permissionDenied == 1)
    }

    @Test("exit 2 that names no file still never reports zero unreadable")
    func exitTwoBackstop() async throws {
        let fixture = try ScannerFixture.replaying(
            okLines(3) + [.stdout("Unable to allocate memory in scanfile()")], status: 2
        )
        let summary = try #require(await fixture.run().summary)
        #expect(summary.unreadable == 1)
        #expect(summary.permissionDenied == 0)
        #expect(summary.scanned == 3)
    }

    @Test("exit 2 with a fatal ERROR line fails even when files were scanned")
    func exitTwoFatal() async throws {
        let fixture = try ScannerFixture.replaying(
            okLines(2) + [.stderr("ERROR: Can't open file or directory")], status: 2
        )
        let events = await fixture.run()
        #expect(events.failure?.contains("Can't open file or directory") == true)
        #expect(events.summary == nil)
    }

    @Test("exit 1 keeps the counts when unreadable files were also met (infection takes priority upstream)")
    func exitOneKeepsCounts() async throws {
        let fixture = try ScannerFixture.replaying([
            .stdout("/t/e: Eicar FOUND"), .stdout("/t/x: Access denied"), .stdout("/t/a: OK")
        ], status: 1)
        let summary = try #require(await fixture.run().summary)
        #expect(summary.findings == 1)
        #expect(summary.unreadable == 1)
        #expect(summary.scanned == 2)
    }

    @Test("a huge number of unreadable files is counted past the dedupe cap")
    func unreadableCap() async throws {
        let total = ScanTally.maxTrackedPaths + 500
        let lines = okLines(1) + (0 ..< total).map { ProcessLine.stdout("/t/denied\($0): Access denied") }
        let fixture = try ScannerFixture.replaying(lines, status: 2)
        let summary = try #require(await fixture.run().summary)
        #expect(summary.unreadable == total)
        #expect(summary.permissionDenied == total)
    }

    @Test("a file named like an error cannot become the failure message")
    func fileNameCannotBeTheMessage() async throws {
        let fixture = try ScannerFixture.replaying([
            .stdout("/t/error_log.txt: Empty file"),
            .stdout("/t/warning error.txt: Excluded"),
            .stdout("Scanning /t/error_2.txt"),
            .stderr("ERROR: Database initialization error: no database")
        ], status: 2)
        let message = try #require(await fixture.run().failure)
        #expect(message.contains("Database initialization"))
        #expect(!message.contains("error_log"))
        #expect(!message.contains("warning error"))
        #expect(!message.contains("error_2"))
        let plain = try ScannerFixture.replaying([.stdout("/t/error_log.txt: Empty file")], status: 3)
        let bare = try #require(await plain.run().failure)
        #expect(!bare.contains("error_log"))
    }
}
