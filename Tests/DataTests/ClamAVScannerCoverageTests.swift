import Foundation
@testable import MainternanceData
import MainternanceDomain
import Testing

@Suite("ClamAV scanner coverage")
struct ClamAVScannerCoverageTests {
    private func fixture(folders: [String]) throws -> ScannerFixture {
        let fixture = try ScannerFixture.replaying([], status: 0)
        for folder in folders {
            try FileManager.default.createDirectory(
                at: fixture.temp.url.appendingPathComponent(folder), withIntermediateDirectories: true
            )
        }
        return fixture
    }

    private func path(_ fixture: ScannerFixture, _ relative: String) -> String {
        fixture.temp.url.appendingPathComponent(relative).standardizedFileURL.path
    }

    @Test("a quick scan covers the existing quick folders and nothing else in the home folder")
    func quick() throws {
        let fixture = try fixture(folders: ["Downloads", "Documents"])
        let coverage = fixture.scanner.coverage(of: .quick)
        #expect(coverage.covers(path(fixture, "Downloads/x.pkg")))
        #expect(!coverage.covers(path(fixture, "Documents/x.pkg")))
        #expect(!coverage.covers(path(fixture, "Desktop/x.pkg"))) // the folder does not exist, so it is not walked
    }

    @Test("a full scan covers the home folder but not the cloud folders or the app's own folders")
    func full() throws {
        let fixture = try fixture(folders: [
            "Documents", "Downloads", "Library/Mobile Documents/com~apple~CloudDocs", "Library/CloudStorage/Dropbox",
            "Library/CloudStorageNot"
        ])
        for folder in [fixture.paths.quarantineDirectory, fixture.paths.root.appendingPathComponent("database")] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        let coverage = fixture.scanner.coverage(of: .full)
        #expect(coverage.covers(path(fixture, "Documents/x.pkg")))
        #expect(coverage.covers(path(fixture, "Downloads/x.pkg")))
        #expect(!coverage.covers(path(fixture, "Library/Mobile Documents/com~apple~CloudDocs/x.pkg")))
        #expect(!coverage.covers(path(fixture, "Library/CloudStorage/Dropbox/x.pkg")))
        #expect(!coverage.covers(fixture.paths.quarantineDirectory.appendingPathComponent("a").path))
        #expect(!coverage.covers(fixture.paths.root.appendingPathComponent("database/x").path))
        #expect(coverage.covers(path(fixture, "Library/CloudStorageNot/x.pkg")))
    }

    @Test("cloud folders are only skipped by full scans")
    func quickDoesNotSkipCloud() throws {
        let fixture = try fixture(folders: ["Downloads"])
        let quick = fixture.scanner.coverage(of: .quick)
        #expect(quick.excluded.contains(fixture.paths.quarantineDirectory.standardizedFileURL.path))
        #expect(!quick.excluded.contains { $0.hasSuffix("Library/CloudStorage") })
    }

    @Test("a custom scan covers its folder")
    func custom() throws {
        let fixture = try fixture(folders: [])
        let coverage = fixture.scanner.coverage(of: .custom(fixture.target))
        #expect(coverage.covers(fixture.path("x.pkg")))
        #expect(!coverage.covers(path(fixture, "target2/x.pkg")))
    }

    @Test("coverage is built from the roots and exclusions the scan itself uses, resolved to real paths")
    func sameRulesAsTheScan() throws {
        let fixture = try fixture(folders: ["Downloads"])
        for scope in [ScanScope.quick, .full, .custom(fixture.target)] {
            let coverage = fixture.scanner.coverage(of: scope)
            let roots = ScanScopes.roots(
                for: scope, home: fixture.temp.url, exists: { FileManager.default.fileExists(atPath: $0) }
            )
            #expect(coverage.roots == roots.compactMap { CoveragePaths.realPath($0) })
            let excluded = ScanExclusions.directories(for: scope, home: fixture.temp.url, paths: fixture.paths)
            #expect(excluded.allSatisfy { coverage.excluded.contains($0) })
        }
    }

    @Test("a scan root that is itself a symbolic link is not treated as covered")
    func symlinkedRoot() throws {
        let fixture = try fixture(folders: ["elsewhere/Downloads"])
        try FileManager.default.createSymbolicLink(
            at: fixture.temp.url.appendingPathComponent("Downloads"),
            withDestinationURL: fixture.temp.url.appendingPathComponent("elsewhere/Downloads")
        )
        let coverage = fixture.scanner.coverage(of: .quick)
        #expect(!coverage.covers(path(fixture, "Downloads/x.pkg")))
        #expect(!coverage.covers(path(fixture, "elsewhere/Downloads/x.pkg")))
    }

    @Test("a path below a symbolic link inside a root is not covered, text match or not")
    func pathBelowALink() throws {
        let fixture = try fixture(folders: ["Documents", "outside"])
        try FileManager.default.createSymbolicLink(
            at: fixture.temp.url.appendingPathComponent("Documents/Link"),
            withDestinationURL: fixture.temp.url.appendingPathComponent("outside")
        )
        let coverage = fixture.scanner.coverage(of: .custom(fixture.temp.url.appendingPathComponent("Documents")))
        #expect(coverage.covers(path(fixture, "Documents/x.pkg")))
        #expect(!coverage.covers(path(fixture, "Documents/Link/x.pkg")))
    }

    @Test("a path whose folder does not exist cannot be told to be covered")
    func unknownParent() throws {
        let fixture = try fixture(folders: ["Downloads"])
        #expect(!fixture.scanner.coverage(of: .quick).covers(path(fixture, "Downloads/nope/x.pkg")))
    }

    @Test("a finding whose own file name is a symbolic link is not covered")
    func findingThatIsALink() throws {
        let fixture = try fixture(folders: ["Downloads", "outside"])
        try Data("x".utf8).write(to: fixture.temp.url.appendingPathComponent("Downloads/real.pkg"))
        try FileManager.default.createSymbolicLink(
            at: fixture.temp.url.appendingPathComponent("Downloads/link.pkg"),
            withDestinationURL: fixture.temp.url.appendingPathComponent("outside/target.pkg")
        )
        let coverage = fixture.scanner.coverage(of: .quick)
        #expect(coverage.covers(path(fixture, "Downloads/real.pkg")))
        #expect(!coverage.covers(path(fixture, "Downloads/link.pkg")))
    }
}
