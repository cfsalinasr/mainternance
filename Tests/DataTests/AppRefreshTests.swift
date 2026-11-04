import Foundation
@testable import MainternanceData
import MainternanceDomain
import Testing

/// An app that updated itself (its folder was replaced, so its inode changed) after it was listed.
@Suite("App refreshed by details")
struct AppRefreshTests {
    /// Replaces the app's folder by a new one with the same plist: the new folder exists before the old one goes.
    private func replace(_ fixture: UninstallerFixture, _ url: URL, plist: [String: Any]) throws {
        let staged = try fixture.app("Staged.app", plist: plist, bytes: 100)
        let old = url.deletingLastPathComponent().appendingPathComponent("Old.bak")
        try FileManager.default.moveItem(at: url, to: old)
        try FileManager.default.moveItem(at: staged, to: url)
    }

    @Test("an app replaced between listing and details is refreshed and then moves")
    func replacedAppMoves() async throws {
        let fixture = try UninstallerFixture()
        let app = try await fixture.listedApp()
        let url = URL(fileURLWithPath: app.id)
        try replace(fixture, url, plist: ["CFBundleIdentifier": "com.example.app"])
        #expect(fixture.identity(app.id) != app.identity)
        let details = await fixture.details(app)
        #expect(details.app.identity == fixture.identity(app.id))
        #expect(details.app.id == app.id)
        let trash = fixture.trash()
        let outcome = await fixture.mover(trash).moveToTrash(
            app: details.app, appBytes: details.appBytes, leftovers: [], includeApp: true
        )
        #expect(outcome.appMoved)
        #expect(outcome.appFailure == nil)
    }

    @Test("without the refresh the stale identity is refused (the old behaviour)")
    func staleIdentityRefused() async throws {
        let fixture = try UninstallerFixture()
        let app = try await fixture.listedApp()
        try replace(fixture, URL(fileURLWithPath: app.id), plist: ["CFBundleIdentifier": "com.example.app"])
        let outcome = await fixture.moveApp(app, fixture.trash())
        #expect(!outcome.appMoved)
        #expect(outcome.appFailure == CleanupRefusal.changed.text)
    }

    @Test("a replaced app that now says com.apple. still refuses")
    func replacedByAppleRefuses() async throws {
        let fixture = try UninstallerFixture()
        let app = try await fixture.listedApp()
        try replace(fixture, URL(fileURLWithPath: app.id), plist: ["CFBundleIdentifier": "com.apple.Pages"])
        let details = await fixture.details(app)
        let trash = fixture.trash()
        let outcome = await fixture.mover(trash).moveToTrash(
            app: details.app, appBytes: details.appBytes, leftovers: [], includeApp: true
        )
        #expect(!outcome.appMoved)
        #expect(outcome.appFailure == UninstallRefusal.appleApp.text)
        #expect(trash.calls.isEmpty)
    }

    @Test("a vanished app keeps the app as listed, size 0, and the mover reports it vanished")
    func vanishedKeepsListedApp() async throws {
        let fixture = try UninstallerFixture()
        let app = try await fixture.listedApp()
        try FileManager.default.removeItem(atPath: app.id)
        let details = await fixture.details(app)
        #expect(details.app == app)
        #expect(details.appBytes == 0)
        let outcome = await fixture.moveApp(details.app, fixture.trash())
        #expect(outcome.appFailure == CleanupRefusal.vanished.text)
    }

    @Test("a replaced app with a new identifier finds leftovers by the new identifier")
    func newIdentifierUsed() async throws {
        let fixture = try UninstallerFixture()
        let app = try await fixture.listedApp()
        try fixture.library("Caches/com.example.renamed/a.bin", bytes: 10)
        try replace(fixture, URL(fileURLWithPath: app.id), plist: ["CFBundleIdentifier": "com.example.renamed"])
        let details = await fixture.details(app)
        #expect(details.app.bundleID == "com.example.renamed")
        #expect(details.leftovers.map(\.name) == ["com.example.renamed"])
    }
}
