import Foundation
@testable import MainternanceData
import MainternanceDomain
import Testing

@Suite("App lister")
struct AppListerTests {
    private func list(_ fixture: UninstallerFixture, own: String? = nil) async -> [InstalledApp] {
        await AppLister(applicationFolders: [fixture.applications], ownBundlePath: own).listApps()
    }

    @Test("lists name, identifier and version, sorted by name ignoring case")
    func listsAndSorts() async throws {
        let fixture = try UninstallerFixture()
        try fixture.app("zeta.app", plist: [
            "CFBundleName": "zeta", "CFBundleIdentifier": "com.example.zeta", "CFBundleShortVersionString": "1.2"
        ])
        try fixture.app("Alpha.app", plist: ["CFBundleName": "Alpha", "CFBundleIdentifier": "com.example.alpha"])
        try fixture.app("beta.app", plist: [
            "CFBundleDisplayName": "Beta Shown", "CFBundleName": "beta", "CFBundleIdentifier": "com.example.beta"
        ])
        let apps = await list(fixture)
        #expect(apps.map(\.name) == ["Alpha", "Beta Shown", "zeta"])
        #expect(apps.map(\.bundleID) == ["com.example.alpha", "com.example.beta", "com.example.zeta"])
        #expect(apps.map(\.version) == [nil, nil, "1.2"])
        #expect(apps[0].id == fixture.applications.appendingPathComponent("Alpha.app").path)
        #expect(apps.allSatisfy { $0.identity != nil })
    }

    @Test("macOS's own apps and the running bundle are not listed")
    func exclusions() async throws {
        let fixture = try UninstallerFixture()
        try fixture.app("Safari.app", plist: ["CFBundleIdentifier": "com.apple.Safari"])
        let own = try fixture.app("Mainternance.app", plist: ["CFBundleIdentifier": "com.example.mainternance"])
        try fixture.app("Keep.app", plist: ["CFBundleIdentifier": "com.example.keep"])
        let apps = await list(fixture, own: own.path)
        #expect(apps.map(\.name) == ["Keep"])
    }

    @Test("the running bundle is excluded even when reached through a different spelling of its path")
    func ownBundleResolved() async throws {
        let fixture = try UninstallerFixture()
        let own = try fixture.app("Mainternance.app", plist: ["CFBundleIdentifier": "com.example.mainternance"])
        let spelled = fixture.applications.appendingPathComponent("../Applications/Mainternance.app").path
        let apps = await list(fixture, own: spelled)
        #expect(apps.isEmpty)
        #expect(FileManager.default.fileExists(atPath: own.path))
    }

    @Test("entries that are not real .app folders are skipped")
    func skipsNonApps() async throws {
        let fixture = try UninstallerFixture()
        try fixture.app("Real.app")
        try fixture.app("NotAnApp", plist: nil)
        try Data("x".utf8).write(to: fixture.applications.appendingPathComponent("File.app"))
        try fixture.link(
            fixture.applications.appendingPathComponent("Linked.app"),
            to: "/System/Applications/Chess.app"
        )
        try fixture.link(fixture.applications.appendingPathComponent("Home.app"), to: NSHomeDirectory())
        let apps = await list(fixture)
        #expect(apps.map(\.name) == ["Real"])
    }

    @Test("a missing folder lists nothing")
    func missingFolder() async {
        let lister = AppLister(
            applicationFolders: [URL(fileURLWithPath: "/nonexistent-mainternance-\(UUID().uuidString)")],
            ownBundlePath: nil
        )
        #expect(await lister.listApps().isEmpty)
    }

    @Test("an app without a readable plist is listed by its folder name with no identifier")
    func noPlist() async throws {
        let fixture = try UninstallerFixture()
        try fixture.app("Bare.app", plist: nil)
        let broken = try fixture.app("Broken.app", plist: nil)
        try Data("not a plist".utf8).write(to: broken.appendingPathComponent("Contents/Info.plist"))
        let apps = await list(fixture)
        #expect(apps.map(\.name) == ["Bare", "Broken"])
        #expect(apps.allSatisfy { $0.bundleID == nil && $0.version == nil })
    }

    @Test("a plist larger than 1 MiB and a plist that is a link are not read")
    func plistBounds() async throws {
        let fixture = try UninstallerFixture()
        let big = try fixture.app(
            "Big.app",
            plist: ["CFBundleIdentifier": "com.example.big", "Pad": String(repeating: "a", count: 1_200_000)]
        )
        let linked = try fixture.app("Linked.app", plist: nil)
        let outside = fixture.temp.url.appendingPathComponent("outside.plist")
        try PropertyListSerialization.data(
            fromPropertyList: ["CFBundleIdentifier": "com.example.linked"],
            format: .xml,
            options: 0
        )
        .write(to: outside)
        try fixture.link(linked.appendingPathComponent("Contents/Info.plist"), to: outside.path)
        let apps = await list(fixture)
        #expect(apps.map(\.name) == ["Big", "Linked"])
        #expect(apps.allSatisfy { $0.bundleID == nil })
        #expect(FileManager.default.fileExists(atPath: big.path))
    }

    @Test("a hostile identifier is treated as no identifier")
    func hostileIdentifiers() async throws {
        let fixture = try UninstallerFixture()
        let hostile = ["../../Documents", "a/b", "", String(repeating: "a", count: 5000), "..", "has space", "x\u{1}y"]
        for (index, text) in hostile.enumerated() {
            try fixture.app("H\(index).app", plist: ["CFBundleIdentifier": text])
        }
        let apps = await list(fixture)
        #expect(apps.count == hostile.count)
        #expect(apps.allSatisfy { $0.bundleID == nil })
    }

    @Test("identifier validation")
    func validIdentifier() {
        #expect(AppLister.validIdentifier("com.example.App-1_x") == "com.example.App-1_x")
        #expect(AppLister.validIdentifier(String(repeating: "a", count: 200)) != nil)
        #expect(AppLister.validIdentifier(String(repeating: "a", count: 201)) == nil)
        for bad in [nil, "", "..", ".", "../x", "a/b", "a b", "é", "a\nb"] {
            #expect(AppLister.validIdentifier(bad) == nil)
        }
    }

    @Test("two folders are merged and the same app is listed once")
    func twoFolders() async throws {
        let fixture = try UninstallerFixture()
        let second = fixture.temp.url.appendingPathComponent("UserApps", isDirectory: true)
        try fixture.app("One.app")
        try fixture.app("Two.app", in: second)
        let lister = AppLister(
            applicationFolders: [fixture.applications, second, fixture.applications],
            ownBundlePath: nil
        )
        #expect(await lister.listApps().map(\.name) == ["One", "Two"])
    }
}
