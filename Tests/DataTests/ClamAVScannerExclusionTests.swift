import Foundation
@testable import MainternanceData
import MainternanceDomain
import Testing

@Suite("ClamAV scanner exclusions")
struct ClamAVScannerExclusionTests {
    private func arguments(_ scope: ScanScope, in fixture: ScannerFixture) async throws -> [String] {
        _ = await fixture.run(scope)
        return try #require(fixture.runner.recorded.first).arguments
    }

    @Test("exclusions come before the -- separator for quick, full and custom scans", arguments: [0, 1, 2])
    func placement(index: Int) async throws {
        let fixture = try ScannerFixture.replaying(okLines(1), status: 0)
        let downloads = fixture.temp.url.appendingPathComponent("Downloads", isDirectory: true)
        try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
        let scope = [ScanScope.quick, .full, .custom(fixture.target)][index]
        let args = try await arguments(scope, in: fixture)
        let separator = try #require(args.firstIndex(of: "--"))
        let exclusions = args.filter { $0.hasPrefix("--exclude-dir=") }
        let expectedCount = index == 1 ? 4 : 2
        #expect(exclusions.count == expectedCount)
        #expect(args.indices.filter { args[$0].hasPrefix("--exclude-dir=") }.allSatisfy { $0 < separator })
        #expect(exclusions.contains(ScanExclusions.arguments(for: [fixture.paths.quarantineDirectory.path])[0]))
        #expect(exclusions.contains(ScanExclusions.arguments(for: [fixture.paths.root.path])[0]))
        // Nothing but roots after the separator, none of them an option.
        #expect(args[(separator + 1)...].allSatisfy { $0.hasPrefix("/") })
    }

    @Test("a full scan also skips the cloud folders")
    func cloudFolders() async throws {
        let fixture = try ScannerFixture.replaying(okLines(1), status: 0)
        let args = try await arguments(.full, in: fixture)
        let home = fixture.temp.url.path
        #expect(args.contains { $0.contains("Mobile Documents") && $0.contains(ScanExclusions.escape(home)) })
        #expect(args.contains { $0.contains("CloudStorage") })
    }

    @Test("a finding below the quarantine or ClamAV folder is dropped, a normal one is kept")
    func postFilter() async throws {
        let temp = try TempDirectory()
        let base = temp.url.standardizedFileURL.path
        let support = "\(base)/support"
        let fixture = try ScannerFixture(temp: temp, runner: FakeRunner.replaying([
            .stdout("\(support)/Quarantine/abc.exe: Sig.Q FOUND"),
            .stdout("\(support)/ClamAV/database/daily.cvd: Sig.D FOUND"),
            .stdout("\(support)/Quarantine2/real.exe: Sig.R FOUND"),
            .stdout("\(base)/target/y.exe: Sig.Y FOUND")
        ], status: 1))
        let events = await fixture.run(.custom(temp.url))
        #expect(events.findings.map(\.signature) == ["Sig.R", "Sig.Y"])
        // Dropped silently: a detection inside the app's own folders is not an unattributed detection.
        #expect(events.summary?.unattributedDetections == 0)
    }

    @Test("a FOUND inside an excluded cloud folder is delivered as a normal finding")
    func cloudFoundDelivered() async throws {
        let temp = try TempDirectory()
        let base = temp.url.standardizedFileURL.path
        let fixture = try ScannerFixture(temp: temp, runner: FakeRunner.replaying([
            .stdout("\(base)/Library/Mobile Documents/com~apple~CloudDocs/a.exe: Sig.I FOUND"),
            .stdout("\(base)/Library/CloudStorage/Dropbox/b.exe: Sig.D FOUND"),
            .stdout("\(base)/Library/CloudStorage/Dropbox/ok.txt: OK")
        ], status: 1))
        let events = await fixture.run(.full)
        #expect(events.findings.map(\.signature) == ["Sig.I", "Sig.D"])
        let summary = try #require(events.summary)
        #expect(summary.findings == 2)
        #expect(summary.unattributedDetections == 0)
        // An OK line below an excluded folder is still post-filtered.
        #expect(summary.scanned == 2)
    }

    @Test("a FOUND inside the quarantine folder is dropped without raising unattributed detections")
    func quarantineFoundSilent() async throws {
        let temp = try TempDirectory()
        let base = temp.url.standardizedFileURL.path
        let fixture = try ScannerFixture(temp: temp, runner: FakeRunner.replaying([
            .stdout("\(base)/support/Quarantine/abc.exe: Sig.Q FOUND"),
            .stdout("\(base)/x.exe: Sig.X FOUND")
        ], status: 1))
        let events = await fixture.run(.full)
        #expect(events.findings.map(\.signature) == ["Sig.X"])
        #expect(events.summary?.unattributedDetections == 0)
    }
}
