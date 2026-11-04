import Foundation
@testable import MainternanceData
import MainternanceDomain
import Testing

@Suite("Leftover finder matching limits")
struct LeftoverFinderMatchTests {
    private func found(_ fixture: UninstallerFixture, _ app: InstalledApp) async -> [Leftover] {
        await fixture.finder.details(for: app).leftovers
    }

    @Test("a hand-built app with a hostile identifier finds nothing by identifier, only exact name matches")
    func hostileIdentifierDirect() async throws {
        let fixture = try UninstallerFixture()
        try fixture.library("Caches/data.bin", bytes: 10)
        try fixture.library("Caches/Documents/a.bin", bytes: 10)
        let documents = fixture.home.appendingPathComponent("Documents", isDirectory: true)
        try FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)
        for hostile in ["../../Documents", "a/b", "..", "", "../Library/Caches", String(repeating: "a", count: 5000)] {
            let app = InstalledApp(
                path: fixture.applications.appendingPathComponent("A.app").path, name: "Documents",
                bundleID: hostile, version: nil
            )
            let leftovers = await found(fixture, app)
            #expect(leftovers.allSatisfy { $0.match == .nameOnly })
            #expect(leftovers.map(\.id) == [fixture.library.appendingPathComponent("Caches/Documents").path])
        }
        #expect(FileManager.default.fileExists(atPath: documents.path))
    }

    @Test("an identifier without dots never turns Group Containers or LaunchAgents into a wildcard")
    func undottedIdentifier() async throws {
        let fixture = try UninstallerFixture()
        for path in [
            "Group Containers/ABCDE12345.app", "Group Containers/other.app", "Group Containers/ABCDE12345.Notes",
            "LaunchAgents/app.plist.plist", "LaunchAgents/app.helper.plist", "LaunchAgents/Notes.x.plist",
            "Group Containers/ABCDE12345.x.app"
        ] {
            try fixture.library(path + "/a.bin", bytes: 10)
        }
        for id in ["app", "Notes", "x"] {
            let app = InstalledApp(path: "/Applications/Z.app", name: "Z", bundleID: id, version: nil)
            #expect(await found(fixture, app).isEmpty)
        }
        let dotted = InstalledApp(path: "/Applications/Z.app", name: "Z", bundleID: "x.app", version: nil)
        #expect(await found(fixture, dotted).map(\.name) == ["ABCDE12345.x.app"])
    }

    @Test("an identifier without dots never ticks a folder that merely shares its name")
    func undottedIdentifierSharesNoFolder() async throws {
        let fixture = try UninstallerFixture()
        try fixture.library("Application Support/Google/a.bin", bytes: 10)
        try fixture.library("Caches/Google/a.bin", bytes: 10)
        let app = InstalledApp(path: "/Applications/Z.app", name: "Z", bundleID: "Google", version: nil)
        #expect(await found(fixture, app).filter { $0.match == .identifier }.isEmpty)
    }

    @Test("Group Containers take exactly one capital team segment before the identifier")
    func teamPrefix() async throws {
        let fixture = try UninstallerFixture()
        let app = try await fixture.installed()
        for path in [
            "ABCDE12345.com.example.app", "abc.def.com.example.app", "abcde12345.com.example.app",
            "ABC.DEF.com.example.app", ".com.example.app", "AB-C.com.example.app", "ABCDE12345.com.example.app2"
        ] {
            try fixture.library("Group Containers/" + path + "/a.bin", bytes: 10)
        }
        let leftovers = await found(fixture, app)
        #expect(leftovers.map(\.name) == ["ABCDE12345.com.example.app"])
    }

    @Test("a name of zero-width characters does not count toward the 4-character minimum")
    func invisibleName() async throws {
        let fixture = try UninstallerFixture()
        let invisible = "\u{200B}\u{200B}\u{200B}\u{200B}"
        try fixture.library("Caches/\(invisible)/a.bin", bytes: 10)
        try fixture.library("Caches/Ab/a.bin", bytes: 10)
        let app = InstalledApp(path: "/Applications/Z.app", name: invisible + "Ab", bundleID: nil, version: nil)
        #expect(await found(fixture, app).isEmpty)
        let hidden = InstalledApp(path: "/Applications/Z.app", name: invisible, bundleID: nil, version: nil)
        #expect(await found(fixture, hidden).isEmpty)
    }
}
