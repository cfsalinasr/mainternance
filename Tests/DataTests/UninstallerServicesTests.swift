import Foundation
@testable import MainternanceData
import MainternanceDomain
import Testing

/// The public Uninstaller pieces, built over a temp home, a temp Applications folder and a fake Trash only.
@Suite("Uninstaller services")
struct UninstallerServicesTests {
    private func services(
        _ fixture: UninstallerFixture, _ trash: NumberedTrash, isRunning: @escaping @Sendable (String) -> Bool
    ) -> UninstallerServices {
        UninstallerServices(
            home: fixture.home, applicationFolders: [fixture.applications], isRunning: isRunning,
            trash: { try trash.trash($0) }
        )
    }

    @Test("list, find and move work together inside the temp folders only")
    func endToEnd() async throws {
        let fixture = try UninstallerFixture()
        let url = try fixture.app("Example.app", plist: ["CFBundleIdentifier": "com.example.app"], bytes: 5000)
        try fixture.library("Caches/com.example.app/a.bin", bytes: 1000)
        let trash = fixture.trash()
        let services = services(fixture, trash, isRunning: { _ in false })
        let app = try #require(await services.lister.listApps().first)
        #expect(app.id == url.path)
        let details = await services.finder.details(for: app)
        #expect(details.leftovers.map(\.location) == ["Caches"])
        let outcome = await services.mover.moveToTrash(
            app: app, appBytes: details.appBytes, leftovers: details.leftovers, includeApp: true
        )
        #expect(outcome.appMoved)
        #expect(outcome.movedLeftovers == details.leftovers)
        #expect(trash.moves.map(\.source.path) == ([url.path] + details.leftovers.map(\.id)).map(fixture.real))
        #expect(!fixture.exists(url.path))
    }

    @Test("the running check given to the services is used")
    func runningCheckWired() async throws {
        let fixture = try UninstallerFixture()
        try fixture.app("Example.app", plist: ["CFBundleIdentifier": "com.example.app"])
        let trash = fixture.trash()
        let services = services(fixture, trash, isRunning: { $0 == "com.example.app" })
        let app = try #require(await services.lister.listApps().first)
        let outcome = await services.mover.moveToTrash(app: app, appBytes: 1, leftovers: [], includeApp: true)
        #expect(outcome.appFailure == UninstallRefusal.running.text)
        #expect(trash.calls.isEmpty)
    }

    @Test("the services use the real protected-places guard")
    func realGuardWired() async throws {
        let fixture = try UninstallerFixture()
        try fixture.app("Example.app", plist: ["CFBundleIdentifier": "com.example.app"])
        let caches = fixture.library.appendingPathComponent("Caches", isDirectory: true)
        try fixture.link(caches.appendingPathComponent("com.example.app"), to: "/System")
        let trash = fixture.trash()
        let services = services(fixture, trash, isRunning: { _ in false })
        let app = try #require(await services.lister.listApps().first)
        let details = await services.finder.details(for: app)
        let outcome = await services.mover.moveToTrash(
            app: app, appBytes: 1, leftovers: details.leftovers, includeApp: false
        )
        #expect(outcome.failedLeftovers.map(\.reason) == [CleanupRefusal.protectedLink.text])
        #expect(trash.calls.isEmpty)
    }

    @Test("the standard application folders are /Applications and the owner's ~/Applications")
    func standardFolders() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        #expect(UninstallerServices.standardApplicationFolders.map(\.path) == [
            "/Applications", home.appendingPathComponent("Applications").path
        ])
    }

    @Test("the real running check says no for an identifier nothing has")
    func realRunningCheck() {
        #expect(!UninstallerServices.isRunning("com.example.mainternance-test-\(UUID().uuidString)"))
    }
}
