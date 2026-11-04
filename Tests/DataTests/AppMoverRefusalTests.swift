import Foundation
@testable import MainternanceData
import MainternanceDomain
import Testing

/// What the mover refuses, with its reason, right before each move. Only a temp Applications folder and a temp home.
@Suite("App mover refusals")
struct AppMoverRefusalTests {
    @Test("an app outside the application folders, or not ending .app, is refused", arguments: [
        "Elsewhere/Thing.app", "Applications/Sub/Thing.app", "Applications/Tool", "Applications/../Thing.app",
        "Applications/Thing.app/", "Applications"
    ])
    func appNotInFolder(relative: String) async throws {
        let fixture = try UninstallerFixture()
        let url = fixture.temp.url.appendingPathComponent(relative, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let path = relative.hasSuffix("/") ? url.path + "/" : url.path
        let forged = InstalledApp(
            path: path,
            name: "Thing",
            bundleID: nil,
            version: nil,
            identity: fixture.identity(url.path)
        )
        let trash = fixture.trash()
        let outcome = await fixture.moveApp(forged, trash)
        #expect(outcome.appFailure == UninstallRefusal.notInUninstallerFolder.text)
        #expect(outcome.skipped.count == 1)
        #expect(trash.calls.isEmpty)
        #expect(fixture.exists(url.path))
    }

    @Test("an app reached through a linked folder inside Applications is refused")
    func appThroughLinkedParent() async throws {
        let fixture = try UninstallerFixture()
        let elsewhere = fixture.temp.url.appendingPathComponent("Elsewhere", isDirectory: true)
        let app = try fixture.app("Victim.app", in: elsewhere)
        try fixture.link(fixture.applications.appendingPathComponent("hop"), to: elsewhere.path)
        let path = fixture.applications.appendingPathComponent("hop/Victim.app").path
        let forged = InstalledApp(
            path: path,
            name: "Victim",
            bundleID: nil,
            version: nil,
            identity: fixture.identity(app.path)
        )
        let trash = fixture.trash()
        let outcome = await fixture.moveApp(forged, trash)
        #expect(outcome.appFailure == UninstallRefusal.notInUninstallerFolder.text)
        #expect(trash.calls.isEmpty)
        #expect(fixture.exists(app.path))
    }

    @Test("an app replaced by a link named like it is refused as changed, and the link target stays")
    func appBecameLink() async throws {
        let fixture = try UninstallerFixture()
        let app = try await fixture.listedApp()
        try FileManager.default.removeItem(atPath: app.id)
        try fixture.link(URL(fileURLWithPath: app.id), to: "/System/Applications/Chess.app")
        let trash = fixture.trash()
        let outcome = await fixture.moveApp(app, trash)
        #expect(outcome.appFailure == CleanupRefusal.changed.text)
        #expect(trash.calls.isEmpty)
        #expect(fixture.exists(app.id))
    }

    @Test("an app replaced by another folder of the same name is refused as changed")
    func appReplaced() async throws {
        let fixture = try UninstallerFixture()
        let app = try await fixture.listedApp()
        try FileManager.default.removeItem(atPath: app.id)
        try fixture.app("Example.app", plist: ["CFBundleIdentifier": "com.example.app"])
        let trash = fixture.trash()
        let outcome = await fixture.moveApp(app, trash)
        #expect(outcome.appFailure == CleanupRefusal.changed.text)
        #expect(trash.calls.isEmpty)
    }

    @Test("an app that is gone is reported as no longer there, and its leftovers are skipped")
    func appVanished() async throws {
        let fixture = try UninstallerFixture()
        let app = try await fixture.listedApp()
        try FileManager.default.removeItem(atPath: app.id)
        let trash = fixture.trash()
        let outcome = await fixture.moveApp(app, trash)
        #expect(outcome.appFailure == CleanupRefusal.vanished.text)
        #expect(outcome.skipped.count == 1)
        #expect(trash.calls.isEmpty)
    }

    @Test("an app on another volume is refused")
    func appOtherVolume() async throws {
        let fixture = try UninstallerFixture()
        let app = try await fixture.listedApp()
        let trash = fixture.trash()
        let mover = fixture.mover(trash, volume: { path, info in
            path.hasSuffix(".app") ? info.device &+ 1 : info.device
        })
        let outcome = await fixture.moveApp(app, trash, using: mover)
        #expect(outcome.appFailure == UninstallRefusal.otherVolume.text)
        #expect(trash.calls.isEmpty)
    }

    @Test("a protected app (the running bundle, a system place, the home folder) is refused")
    func appProtected() async throws {
        let fixture = try UninstallerFixture()
        let app = try await fixture.listedApp()
        let trash = fixture.trash()
        let target = fixture.real(app.id)
        let mover = fixture.mover(trash, isProtected: { $0 == target })
        let outcome = await fixture.moveApp(app, trash, using: mover)
        #expect(outcome.appFailure == CleanupRefusal.protected.text)
        #expect(trash.calls.isEmpty)
    }

    @Test("an app with no recorded identity cannot be checked, so it is left alone")
    func appWithoutIdentity() async throws {
        let fixture = try UninstallerFixture()
        let app = try await fixture.listedApp()
        let bare = InstalledApp(path: app.id, name: app.name, bundleID: app.bundleID, version: nil)
        let trash = fixture.trash()
        let outcome = await fixture.moveApp(bare, trash)
        #expect(outcome.appFailure == CleanupRefusal.unreadable.text)
        #expect(trash.calls.isEmpty)
    }

    @Test("an application folder that is a link is never used")
    func linkedApplicationsFolder() async throws {
        let fixture = try UninstallerFixture()
        let real = fixture.temp.url.appendingPathComponent("RealApps", isDirectory: true)
        let app = try fixture.app("Example.app", in: real, plist: ["CFBundleIdentifier": "com.example.app"])
        let linked = fixture.temp.url.appendingPathComponent("LinkedApps")
        try fixture.link(linked, to: real.path)
        let trash = fixture.trash()
        let mover = AppMover(
            home: fixture.home, applicationFolders: [linked], isRunning: { _ in false },
            trash: { try trash.trash($0) }, isProtected: { ProtectedPaths.isProtected($0) }
        )
        let forged = InstalledApp(
            path: linked.appendingPathComponent("Example.app").path, name: "Example", bundleID: "com.example.app",
            version: nil, identity: fixture.identity(app.path)
        )
        let outcome = await fixture.moveApp(forged, trash, using: mover)
        #expect(outcome.appFailure == UninstallRefusal.notInUninstallerFolder.text)
        #expect(trash.calls.isEmpty)
    }
}
