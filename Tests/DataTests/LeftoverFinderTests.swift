import Foundation
@testable import MainternanceData
import MainternanceDomain
import Testing

@Suite("Leftover finder")
struct LeftoverFinderTests {
    private let id = "com.example.app"

    private func found(_ fixture: UninstallerFixture, _ app: InstalledApp) async -> [Leftover] {
        await fixture.finder.details(for: app).leftovers
    }

    @Test("every fixed location is found for an exact identifier, and ticked")
    func everyLocation() async throws {
        let fixture = try UninstallerFixture()
        let app = try await fixture.installed()
        let paths = [
            "Application Support/com.example.app", "Caches/com.example.app", "Containers/com.example.app",
            "Group Containers/com.example.app", "Group Containers/ABCDE12345.com.example.app",
            "Preferences/com.example.app.plist", "Saved Application State/com.example.app.savedState",
            "HTTPStorages/com.example.app", "WebKit/com.example.app", "Cookies/com.example.app.binarycookies",
            "Logs/com.example.app"
        ]
        for path in paths {
            if path.contains(".plist") || path.contains("binarycookies") {
                try fixture.library(path, bytes: 100)
            } else {
                try fixture.library(path + "/data.bin", bytes: 100)
            }
        }
        let leftovers = await found(fixture, app)
        #expect(Set(leftovers.map(\.id)) == Set(paths.map { fixture.library.appendingPathComponent($0).path }))
        #expect(leftovers.allSatisfy { $0.match == .identifier && $0.match.isSelectedByDefault })
        let location = leftovers.first { $0.name == "ABCDE12345.com.example.app" }?.location
        #expect(location == "Group Containers")
    }

    @Test("lookalike identifiers and names are not found")
    func lookalikes() async throws {
        let fixture = try UninstallerFixture()
        let app = try await fixture.installed()
        for path in [
            "Application Support/com.example.app2", "Caches/xcom.example.app", "Caches/com.example.app.extra",
            "Containers/xcom.example.app", "Group Containers/ABCDE12345.xcom.example.app",
            "Group Containers/com.example.app2", "Preferences/com.example.app2.plist",
            "Preferences/xcom.example.app.plist", "Saved Application State/com.example.app2.savedState",
            "Cookies/com.example.app2.binarycookies", "Logs/COM.EXAMPLE.APP", "LaunchAgents/com.example.app2.plist",
            "LaunchAgents/xcom.example.app.plist"
        ] {
            try fixture.library(path, bytes: 10)
        }
        #expect(await found(fixture, app).isEmpty)
    }

    @Test("a hostile identifier builds no path outside the fixed folders")
    func hostileIdentifier() async throws {
        let fixture = try UninstallerFixture()
        try fixture.library("Caches/data.bin", bytes: 10)
        let documents = fixture.home.appendingPathComponent("Documents", isDirectory: true)
        try FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)
        for (index, text) in ["../../Documents", "a/b", "", String(repeating: "a", count: 5000)].enumerated() {
            let url = try fixture.app("X\(index).app", plist: ["CFBundleIdentifier": text, "CFBundleName": "Hostile"])
            let apps = await fixture.listed()
            let app = try #require(apps.first { $0.id == url.path })
            #expect(app.bundleID == nil)
            #expect(await found(fixture, app).isEmpty)
        }
        #expect(FileManager.default.fileExists(atPath: documents.path))
    }

    @Test("a hand-built app with a hostile identifier still finds nothing by identifier")
    func hostileIdentifierDirect() async throws {
        let fixture = try UninstallerFixture()
        try fixture.library("Caches/data.bin", bytes: 10)
        let app = InstalledApp(
            path: fixture.applications.appendingPathComponent("A.app").path,
            name: "a",
            bundleID: nil,
            version: nil
        )
        #expect(await found(fixture, app).isEmpty)
    }

    @Test("name matches are name-only, unticked, case-insensitive and exact")
    func nameMatches() async throws {
        let fixture = try UninstallerFixture()
        let app = try await fixture.installed("Fancy.app", id: nil, name: "Fancy Tool")
        try fixture.library("Application Support/fancy tool/a.bin", bytes: 100)
        try fixture.library("Logs/FANCY TOOL/a.bin", bytes: 100)
        try fixture.library("Caches/Fancy Tool/a.bin", bytes: 100)
        try fixture.library("Caches/Fancy Tool Pro/a.bin", bytes: 100)
        try fixture.library("Containers/Fancy Tool/a.bin", bytes: 100)
        let leftovers = await found(fixture, app)
        #expect(Set(leftovers.map(\.location)) == ["Application Support", "Logs", "Caches"])
        #expect(leftovers.count == 3)
        #expect(leftovers.allSatisfy { $0.match == .nameOnly && !$0.match.isSelectedByDefault })
    }

    @Test("short or generic names do not pull in other folders")
    func shortNames() async throws {
        let fixture = try UninstallerFixture()
        try fixture.library("Application Support/Go/a.bin", bytes: 10)
        try fixture.library("Caches/Ab/a.bin", bytes: 10)
        let short = try await fixture.installed("Go.app", id: nil, name: "Go")
        #expect(await found(fixture, short).isEmpty)
        let three = try await fixture.installed("Abc.app", id: nil, name: "Abc")
        try fixture.library("Caches/Abc/a.bin", bytes: 10)
        #expect(await found(fixture, three).isEmpty)
        let four = try await fixture.installed("Note.app", id: nil, name: "Note")
        try fixture.library("Caches/Note/a.bin", bytes: 10)
        #expect(await found(fixture, four).count == 1)
    }

    @Test("an identifier match wins over a name match of the same folder")
    func identifierWins() async throws {
        let fixture = try UninstallerFixture()
        let app = try await fixture.installed("Fancy.app", id: "com.example.fancy", name: "com.example.fancy")
        try fixture.library("Caches/com.example.fancy/a.bin", bytes: 10)
        let leftovers = await found(fixture, app)
        #expect(leftovers.count == 1)
        #expect(leftovers.first?.match == .identifier)
    }

    @Test("two apps with the same name do not take each other's identifier folders")
    func sameName() async throws {
        let fixture = try UninstallerFixture()
        let first = try await fixture.installed("Notes One.app", id: "com.one.notes", name: "Notes")
        try fixture.library("Caches/com.one.notes/a.bin", bytes: 10)
        try fixture.library("Caches/com.two.notes/a.bin", bytes: 10)
        let leftovers = await found(fixture, first)
        #expect(leftovers.map(\.name) == ["com.one.notes"])
    }

    @Test("launch agents are listed, unticked, by exact identifier or identifier prefix")
    func launchAgents() async throws {
        let fixture = try UninstallerFixture()
        let app = try await fixture.installed()
        try fixture.library("LaunchAgents/com.example.app.plist", bytes: 50)
        try fixture.library("LaunchAgents/com.example.app.helper.plist", bytes: 50)
        try fixture.library("LaunchAgents/com.example.apple.plist", bytes: 50)
        let leftovers = await found(fixture, app)
        #expect(Set(leftovers.map(\.name)) == ["com.example.app.plist", "com.example.app.helper.plist"])
        #expect(leftovers.allSatisfy { $0.match == .launchAgent && !$0.match.isSelectedByDefault })
        #expect(leftovers.allSatisfy { $0.location == "LaunchAgents" })
    }

    @Test("sizes are about the written bytes, and leftovers come largest first")
    func sizesAndOrder() async throws {
        let fixture = try UninstallerFixture()
        let app = try await fixture.installed()
        try fixture.library("Caches/com.example.app/a.bin", bytes: 5000)
        try fixture.library("Caches/com.example.app/sub/b.bin", bytes: 3000)
        try fixture.library("Preferences/com.example.app.plist", bytes: 200_000)
        try fixture.library("Logs/com.example.app/c.bin", bytes: 10)
        let leftovers = await found(fixture, app)
        #expect(leftovers.map(\.location) == ["Preferences", "Caches", "Logs"])
        #expect(isAbout(leftovers[0].bytes, 200_000))
        #expect(isAbout(leftovers[1].bytes, 8000))
        #expect(isAbout(leftovers[2].bytes, 10))
        #expect(leftovers.allSatisfy { !$0.isLowerBound })
        #expect(leftovers[0].type == .file && leftovers[1].type == .directory)
        #expect(leftovers.allSatisfy { $0.identity != nil })
    }

    @Test("the app's own size is measured when its details are read")
    func appSize() async throws {
        let fixture = try UninstallerFixture()
        let url = try fixture.app("Big.app", plist: ["CFBundleIdentifier": "com.example.big"], bytes: 300_000)
        let app = try #require(await fixture.listed().first { $0.id == url.path })
        let details = await fixture.finder.details(for: app)
        #expect(details.appBytes >= 300_000)
        #expect(details.appBytes < 300_000 + 1_048_576)
        #expect(!details.appIsLowerBound)
        #expect(details.app == app)
    }

    @Test("a leftover that is a link counts as the link itself and is never followed")
    func linkLeftover() async throws {
        let fixture = try UninstallerFixture()
        let app = try await fixture.installed()
        let target = fixture.temp.url.appendingPathComponent("target", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try fixture.payload(2_000_000).write(to: target.appendingPathComponent("huge.bin"))
        try fixture.link(fixture.library.appendingPathComponent("Caches/com.example.app"), to: target.path)
        try fixture.link(
            fixture.library.appendingPathComponent("Application Support/com.example.app"),
            to: NSHomeDirectory()
        )
        let leftovers = await found(fixture, app)
        #expect(leftovers.count == 2)
        #expect(leftovers.allSatisfy { $0.type == .symbolicLink && $0.bytes < 100_000 && !$0.isLowerBound })
    }

    @Test("a nested link inside a leftover folder is not followed")
    func nestedLink() async throws {
        let fixture = try UninstallerFixture()
        let app = try await fixture.installed()
        let target = fixture.temp.url.appendingPathComponent("target", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try fixture.payload(2_000_000).write(to: target.appendingPathComponent("huge.bin"))
        try fixture.library("Caches/com.example.app/a.bin", bytes: 100)
        try fixture.link(fixture.library.appendingPathComponent("Caches/com.example.app/out"), to: target.path)
        let leftovers = await found(fixture, app)
        #expect(leftovers.count == 1)
        #expect(leftovers[0].bytes < 100_000)
    }

    @Test("a fixed folder that is a link is not read")
    func linkedFolder() async throws {
        let fixture = try UninstallerFixture()
        let app = try await fixture.installed()
        let outside = fixture.temp.url.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(
            at: outside.appendingPathComponent("com.example.app"), withIntermediateDirectories: true
        )
        try fixture.link(fixture.library.appendingPathComponent("Caches"), to: outside.path)
        #expect(await found(fixture, app).isEmpty)
    }

    @Test("a missing Library finds nothing")
    func noLibrary() async throws {
        let fixture = try UninstallerFixture()
        let app = try await fixture.installed()
        try FileManager.default.removeItem(at: fixture.library)
        #expect(await found(fixture, app).isEmpty)
    }

    @Test("a cancelled read returns at once with folder sizes as lower bounds")
    func cancellation() async throws {
        let fixture = try UninstallerFixture()
        let app = try await fixture.installed()
        try fixture.library("Caches/com.example.app/a.bin", bytes: 1000)
        try fixture.library("Preferences/com.example.app.plist", bytes: 1000)
        let finder = fixture.finder
        let task = Task {
            while !Task.isCancelled {
                await Task.yield()
            }
            return await finder.details(for: app)
        }
        task.cancel()
        let details = await task.value
        let folder = try #require(details.leftovers.first { $0.type == .directory })
        #expect(folder.isLowerBound)
        let file = try #require(details.leftovers.first { $0.type == .file })
        #expect(!file.isLowerBound)
    }
}
