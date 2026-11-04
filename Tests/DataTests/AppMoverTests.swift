import Foundation
@testable import MainternanceData
import MainternanceDomain
import Testing

/// Moving an app and its leftovers to a fake Trash folder: the app first, guarded, never a permanent delete. Only a
/// temp Applications folder and a temp home are used.
@Suite("App mover")
struct AppMoverTests {
    /// An app with an identifier and three leftovers (a folder, a plist and a log folder).
    private func setUp(_ fixture: UninstallerFixture) async throws -> AppDetails {
        let url = try fixture.app("Example.app", plist: ["CFBundleIdentifier": "com.example.app"], bytes: 20000)
        try fixture.library("Caches/com.example.app/a.bin", bytes: 3000)
        try fixture.library("Preferences/com.example.app.plist", bytes: 100)
        try fixture.library("Logs/com.example.app/x.log", bytes: 500)
        let app = try #require(await fixture.listed().first { $0.id == url.path })
        let details = await fixture.details(app)
        #expect(details.leftovers.count == 3)
        return details
    }

    @Test("the app moves first, then its leftovers; the outcome lists what really moved")
    func movesAppThenLeftovers() async throws {
        let fixture = try UninstallerFixture()
        let details = try await setUp(fixture)
        let trash = fixture.trash()
        let outcome = await fixture.mover(trash).moveToTrash(
            app: details.app, appBytes: details.appBytes, leftovers: details.leftovers, includeApp: true
        )
        #expect(outcome.appMoved)
        #expect(outcome.appFailure == nil)
        #expect(outcome.movedLeftovers == details.leftovers)
        #expect(outcome.failedLeftovers.isEmpty)
        #expect(outcome.skipped.isEmpty)
        #expect(outcome.movedBytes == details.appBytes + details.leftovers.reduce(0) { $0 + $1.bytes })
        // The real moved paths: the app first, then each leftover in the order given.
        #expect(trash.moves.map(\.source.path) == ([details.app.id] + details.leftovers.map(\.id)).map(fixture.real))
        for move in trash.moves {
            #expect(!fixture.exists(move.source.path))
            #expect(fixture.exists(move.destination.path))
        }
        #expect(fixture.exists(trash.moves[0].destination.appendingPathComponent("Contents/Info.plist").path))
    }

    @Test("with the app unticked, only the leftovers move and the app stays")
    func leftoversOnly() async throws {
        let fixture = try UninstallerFixture()
        let details = try await setUp(fixture)
        let trash = fixture.trash()
        let outcome = await fixture.mover(trash).moveToTrash(
            app: details.app, appBytes: details.appBytes, leftovers: details.leftovers, includeApp: false
        )
        #expect(!outcome.appMoved)
        #expect(outcome.appFailure == nil)
        #expect(outcome.movedLeftovers == details.leftovers)
        #expect(outcome.movedBytes == details.leftovers.reduce(0) { $0 + $1.bytes })
        #expect(trash.moves.map(\.source.path) == details.leftovers.map(\.id).map(fixture.real))
        #expect(fixture.exists(details.app.id))
    }

    @Test("leftovers only: a running app refuses every leftover and the Trash is never called")
    func leftoversOnlyRunning() async throws {
        let fixture = try UninstallerFixture()
        let details = try await setUp(fixture)
        let trash = fixture.trash()
        let outcome = await fixture.mover(trash, isRunning: { $0 == "com.example.app" }).moveToTrash(
            app: details.app, appBytes: details.appBytes, leftovers: details.leftovers, includeApp: false
        )
        #expect(!outcome.appMoved)
        #expect(outcome.movedLeftovers.isEmpty)
        #expect(outcome.failedLeftovers.map(\.leftover) == details.leftovers)
        #expect(outcome.failedLeftovers.allSatisfy { $0.reason == UninstallRefusal.running.text })
        #expect(outcome.movedBytes == 0)
        #expect(trash.calls.isEmpty)
    }

    @Test("a running app is refused with 'Quit it first'; no leftover is tried and the Trash is never called")
    func runningSkipsEverything() async throws {
        let fixture = try UninstallerFixture()
        let details = try await setUp(fixture)
        let trash = fixture.trash()
        let outcome = await fixture.mover(trash, isRunning: { $0 == "com.example.app" }).moveToTrash(
            app: details.app, appBytes: details.appBytes, leftovers: details.leftovers, includeApp: true
        )
        #expect(!outcome.appMoved)
        #expect(outcome.appFailure == UninstallRefusal.running.text)
        #expect(outcome.appFailure?.contains("Quit it first") == true)
        #expect(outcome.skipped == details.leftovers)
        #expect(outcome.movedLeftovers.isEmpty)
        #expect(outcome.failedLeftovers.isEmpty)
        #expect(outcome.movedBytes == 0)
        #expect(trash.calls.isEmpty)
        #expect(fixture.exists(details.app.id))
        #expect(details.leftovers.allSatisfy { fixture.exists($0.id) })
    }

    @Test("when macOS refuses to move the app, its leftovers are skipped and nothing counts as moved")
    func appTrashFailureSkipsLeftovers() async throws {
        let fixture = try UninstallerFixture()
        let details = try await setUp(fixture)
        let trash = fixture.trash(refuses: { $0.lastPathComponent == "Example.app" })
        let outcome = await fixture.mover(trash).moveToTrash(
            app: details.app, appBytes: details.appBytes, leftovers: details.leftovers, includeApp: true
        )
        #expect(!outcome.appMoved)
        let reason = try #require(outcome.appFailure)
        #expect(reason.hasPrefix("macOS could not move it to the Trash: "))
        #expect(outcome.skipped == details.leftovers)
        #expect(outcome.movedBytes == 0)
        #expect(trash.calls.map(\.path) == [fixture.real(details.app.id)])
        #expect(details.leftovers.allSatisfy { fixture.exists($0.id) })
    }

    @Test("an app whose Info.plist now says com.apple is refused, even when asked directly")
    func appleIdentifierReread() async throws {
        let fixture = try UninstallerFixture()
        let details = try await setUp(fixture)
        let plist = URL(fileURLWithPath: details.app.id).appendingPathComponent("Contents/Info.plist")
        try PropertyListSerialization.data(
            fromPropertyList: ["CFBundleIdentifier": " COM.APPLE.Safari"], format: .xml, options: 0
        ).write(to: plist)
        let trash = fixture.trash()
        let outcome = await fixture.mover(trash).moveToTrash(
            app: details.app, appBytes: details.appBytes, leftovers: details.leftovers, includeApp: true
        )
        #expect(outcome.appFailure == UninstallRefusal.appleApp.text)
        #expect(outcome.skipped == details.leftovers)
        #expect(trash.calls.isEmpty)
    }

    @Test("a com.apple app never listed, forged by path, is refused")
    func appleAppForged() async throws {
        let fixture = try UninstallerFixture()
        let url = try fixture.app("Safari.app", plist: ["CFBundleIdentifier": "com.apple.Safari"])
        guard case let .found(info) = ItemStat.read(url.path) else {
            Issue.record("no app")
            return
        }
        let forged = InstalledApp(
            path: url.path, name: "Safari", bundleID: "com.example.safari", version: nil, identity: info.identity
        )
        let trash = fixture.trash()
        let outcome = await fixture.mover(trash).moveToTrash(app: forged, appBytes: 1, leftovers: [], includeApp: true)
        #expect(outcome.appFailure == UninstallRefusal.appleApp.text)
        #expect(trash.calls.isEmpty)
        #expect(fixture.exists(url.path))
    }

    @Test("an identifier changed in the Info.plist since listing is refused as changed")
    func identifierChanged() async throws {
        let fixture = try UninstallerFixture()
        let details = try await setUp(fixture)
        let plist = URL(fileURLWithPath: details.app.id).appendingPathComponent("Contents/Info.plist")
        try PropertyListSerialization.data(
            fromPropertyList: ["CFBundleIdentifier": "com.example.other"], format: .xml, options: 0
        ).write(to: plist)
        let trash = fixture.trash()
        let outcome = await fixture.mover(trash).moveToTrash(
            app: details.app, appBytes: details.appBytes, leftovers: [], includeApp: true
        )
        #expect(outcome.appFailure == CleanupRefusal.changed.text)
        #expect(trash.calls.isEmpty)
    }

    @Test("one leftover the Trash refuses does not stop the rest and is never counted as moved")
    func oneLeftoverFails() async throws {
        let fixture = try UninstallerFixture()
        let details = try await setUp(fixture)
        let busy = try #require(details.leftovers.first { $0.location == "Caches" })
        let busyPath = fixture.real(busy.id)
        let trash = fixture.trash(refuses: { $0.path == busyPath })
        let outcome = await fixture.mover(trash).moveToTrash(
            app: details.app, appBytes: details.appBytes, leftovers: details.leftovers, includeApp: true
        )
        #expect(outcome.appMoved)
        #expect(trash.calls.count == 4)
        #expect(outcome.failedLeftovers.map(\.leftover) == [busy])
        let reason = try #require(outcome.failedLeftovers.first?.reason)
        #expect(reason.hasPrefix("macOS could not move it to the Trash: "))
        #expect(outcome.movedLeftovers == details.leftovers.filter { $0 != busy })
        let expected = details.appBytes + outcome.movedLeftovers.reduce(0) { $0 + $1.bytes }
        #expect(outcome.movedBytes == expected)
        #expect(fixture.exists(busy.id))
    }

    @Test("an app with no identifier moves without a running check")
    func noIdentifier() async throws {
        let fixture = try UninstallerFixture()
        let url = try fixture.app("Bare.app", plist: nil)
        let app = try #require(await fixture.listed().first { $0.id == url.path })
        #expect(app.bundleID == nil)
        let trash = fixture.trash()
        let outcome = await fixture.mover(trash, isRunning: { _ in true }).moveToTrash(
            app: app, appBytes: 10, leftovers: [], includeApp: true
        )
        #expect(outcome.appMoved)
        #expect(outcome.movedBytes == 10)
        #expect(trash.moves.map(\.source.path) == [fixture.real(url.path)])
    }
}
