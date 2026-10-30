import Foundation
@testable import MainternanceData
import MainternanceDomain
import Testing

/// A file name can contain newlines and forge whole output lines; verdict paths are vetted.
@Suite("ClamAV scanner forged output")
struct ClamAVScannerForgeryTests {
    @Test("a newline in a file name cannot fake a finding outside the scan roots")
    func newlineAttack() async throws {
        // The folder holds a file named: a\n/Users/me/Documents/thesis.docx: Win.Trojan.X FOUND\nb
        let fixture = try ScannerFixture.replaying([
            .stdout("Scanning /t/a"),
            .stdout("/Users/me/Documents/thesis.docx: Win.Trojan.X FOUND"),
            .stdout("b: OK"),
            .stdout("/t/c: OK")
        ], status: 0)
        let events = await fixture.run()
        #expect(events.findings.isEmpty)
        let summary = try #require(events.summary)
        #expect(summary.findings == 0)
        #expect(summary.scanned == 1)
        // The dropped FOUND line is a detection nobody can attribute: the scan is not clean.
        #expect(summary.unattributedDetections == 1)
        #expect(!summary.isClean)
    }

    @Test("the real detection of a file with a newline in its name is never lost silently")
    func realHostileFileIsCounted() async throws {
        // The folder holds a file named: a\n/Users/me/Documents/thesis.docx: Win.Trojan.X FOUND\nb
        // clamscan reports it as three output lines, and exits 1.
        let fixture = try ScannerFixture.replaying([
            .stdout("/t/a"),
            .stdout("/Users/me/Documents/thesis.docx: Win.Trojan.X FOUND"),
            .stdout("b: Eicar-Signature FOUND"),
            .stdout("/t/c: OK")
        ], status: 1)
        let events = await fixture.run()
        #expect(events.findings.isEmpty)
        let summary = try #require(events.summary)
        #expect(summary.unattributedDetections >= 1)
        #expect(!summary.isClean)
        #expect(summary.findings == 0)
    }

    @Test("exit 1 with an accepted finding has no unattributed detection")
    func normalExitOne() async throws {
        let fixture = try ScannerFixture.replaying([.stdout("/t/e: Eicar FOUND"), .stdout("/t/a: OK")], status: 1)
        let summary = try #require(await fixture.run().summary)
        #expect(summary.findings == 1)
        #expect(summary.unattributedDetections == 0)
        #expect(!summary.isClean)
    }

    @Test("exit 1 although nothing could be parsed counts one unattributed detection")
    func exitOneNothingParsed() async throws {
        let fixture = try ScannerFixture.replaying(okLines(3) + [.stdout("garbled ?!")], status: 1)
        let summary = try #require(await fixture.run().summary)
        #expect(summary.findings == 0)
        #expect(summary.unattributedDetections == 1)
        #expect(!summary.isClean)
    }

    @Test("a clean exit 0 scan has none and is clean")
    func exitZero() async throws {
        let fixture = try ScannerFixture.replaying(okLines(3), status: 0)
        let summary = try #require(await fixture.run().summary)
        #expect(summary.unattributedDetections == 0)
        #expect(summary.isClean)
        #expect(summary.isComplete)
    }

    @Test("a failure after a dropped detection carries the count in its message")
    func failureCarriesCount() async throws {
        let fixture = try ScannerFixture.replaying([.stdout("b: Eicar-Signature FOUND")], status: 3)
        let message = try #require(await fixture.run().failure)
        #expect(message.contains("1 detection(s) could not be attributed"))
    }

    @Test("a forged unreadable or OK line outside the roots counts for nothing")
    func forgedOtherLines() async throws {
        let fixture = try ScannerFixture.replaying([
            .stdout("/etc/hosts: OK"),
            .stdout("/Users/me/Documents: Access denied"),
            .stderr("WARNING: Can't open file /Users/me/x: Permission denied"),
            .stdout("/t/ok: OK")
        ], status: 0)
        let summary = try #require(await fixture.run().summary)
        #expect(summary.scanned == 1)
        #expect(summary.unreadable == 0)
    }

    @Test("a legitimate finding under the root still works, also for a name with a colon")
    func legitimate() async throws {
        let fixture = try ScannerFixture.replaying(
            [.stdout("/t/sub dir/a: b.exe: Win.Test.EICAR_HDB-1 FOUND")],
            status: 1
        )
        let finding = try #require(await fixture.run().findings.first)
        #expect(finding.path == fixture.path("sub dir/a: b.exe"))
        #expect(finding.signature == "Win.Test.EICAR_HDB-1")
    }

    @Test("the root itself counts as inside; a sibling sharing the prefix does not")
    func prefixTrap() async throws {
        let trap = try ScannerFixture.replaying([.stdout("/tb/evil.exe: Sig FOUND"), .stdout("/tb/x: OK")], status: 1)
        let events = await trap.run()
        #expect(events.findings.isEmpty)
        #expect(events.summary?.scanned == 0)
        #expect(ScanPathRules.isInside("/Users/a/x", directory: "/Users/a"))
        #expect(ScanPathRules.isInside("/Users/a", directory: "/Users/a"))
        #expect(!ScanPathRules.isInside("/Users/ab/x", directory: "/Users/a"))
        #expect(!ScanPathRules.isInside("/Users/ab", directory: "/Users/a"))
        #expect(!ScanPathRules.isInside("/anything", directory: "/"))
    }

    @Test("dot-dot components cannot climb out of a root")
    func traversal() async throws {
        let fixture = try ScannerFixture.replaying([
            .stdout("/t/../../outside.exe: Sig FOUND"), .stdout("/t/./x: OK"), .stdout("/t//y: OK")
        ], status: 1)
        let events = await fixture.run()
        #expect(events.findings.isEmpty)
        #expect(events.summary?.scanned == 0)
        #expect(!ScanPathRules.isPlainAbsolute("/a/../b"))
        #expect(!ScanPathRules.isPlainAbsolute("relative"))
        #expect(!ScanPathRules.isPlainAbsolute("/"))
        #expect(ScanPathRules.isPlainAbsolute("/a/b..c/d"))
    }

    @Test("a FOUND path that does not exist is dropped (lstat), a dangling symlink counts as existing")
    func existence() async throws {
        let temp = try TempDirectory()
        let target = temp.url.appendingPathComponent("target", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let root = target.standardizedFileURL.path
        let real = target.appendingPathComponent("real.exe")
        try Data("x".utf8).write(to: real)
        let dangling = target.appendingPathComponent("dangling")
        try FileManager.default.createSymbolicLink(atPath: dangling.path, withDestinationPath: root + "/nowhere")
        let fixture = try ScannerFixture(
            temp: temp,
            fileExists: ScanPathRules.lstatExists,
            runner: FakeRunner.replaying([
                .stdout("\(root)/real.exe: Sig.A FOUND"),
                .stdout("\(root)/missing.exe: Sig.B FOUND"),
                .stdout("\(root)/dangling: Sig.C FOUND")
            ], status: 1)
        )
        let events = await fixture.run()
        #expect(events.findings.map(\.signature) == ["Sig.A", "Sig.C"])
        #expect(events.summary?.findings == 2)
    }

    @Test("the suspicious counter is bounded and informational")
    func counter() {
        var tally = ScanTally()
        for _ in 0 ..< 3 {
            tally.noteSuspicious()
        }
        #expect(tally.ignoredSuspicious == 3)
        #expect(tally.findings == 0)
    }
}
