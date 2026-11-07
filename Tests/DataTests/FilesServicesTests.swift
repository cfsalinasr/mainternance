import Foundation
@testable import MainternanceData
import MainternanceDomain
import Testing

/// The public Files pieces, built over a temp home, a fake Spotlight and a fake Trash only. Spotlight itself, the
/// real home folder and the real Trash are never used.
@Suite("Files services")
struct FilesServicesTests {
    private func services(
        _ fixture: FilesFixture, _ trash: NumberedTrash,
        answer: @escaping @Sendable () -> SpotlightAnswer = { SpotlightAnswer(paths: []) },
        isProtected: @escaping @Sendable (String) -> Bool = { _ in false }
    ) -> FilesServices {
        FilesServices(
            home: fixture.home, runQuery: { _, _, _ in answer() }, trash: { try trash.trash($0) },
            isProtected: isProtected
        )
    }

    @Test("search, disk scan, duplicates and the trasher work together inside the temp folders only")
    func endToEnd() async throws {
        let fixture = try FilesFixture()
        let first = try fixture.write("Documents/copy.bin", pattern(1_100_000))
        let second = try fixture.write("Downloads/copy.bin", pattern(1_100_000))
        let note = try fixture.file("Documents/note.txt")
        let trash = fixture.trash()
        let services = services(fixture, trash, answer: { SpotlightAnswer(paths: [note.path]) })

        let found = await services.search.search(FileSearchQuery(text: "note"))
        #expect(found.files.map(\.id) == [note.path])

        let scan = try #require(await finishedResult(collectUpdates(services.disk.scan())))
        #expect(scan.tree.id == fixture.home.path)
        #expect(child("Documents", of: scan.tree) != nil)

        let updates = await collectDuplicateUpdates(services.duplicates.find())
        let group = try #require(updates.compactMap(\.group).first)
        #expect(group.files.map(\.id) == [first.path, second.path])

        let outcome = await services.trasher.moveDuplicatesToTrash(group, remove: [group.files[1]])
        #expect(outcome.moved.map(\.id) == [second.path])
        #expect(trash.moves.map(\.source.path) == [second.path])
        #expect(fixture.exists(first) && !fixture.exists(second))
    }

    @Test("the Spotlight runner given to the services is used, including its unavailable answer")
    func runQueryWired() async throws {
        let fixture = try FilesFixture()
        let services = services(fixture, fixture.trash(), answer: { SpotlightAnswer(paths: [], isUnavailable: true) })
        let result = await services.search.search(FileSearchQuery(text: "anything"))
        #expect(result.isUnavailable)
    }

    @Test("the protected-places guard given to the services reaches the walk and the trasher")
    func protectedGuardWired() async throws {
        let fixture = try FilesFixture()
        let kept = try fixture.file("Private/secret.bin")
        try fixture.file("Public/open.bin")
        let trash = fixture.trash()
        let services = services(fixture, trash, isProtected: { $0.contains("/Private") })
        let scan = try #require(await finishedResult(collectUpdates(services.disk.scan())))
        #expect(child("Private", of: scan.tree) == nil)
        #expect(child("Public", of: scan.tree) != nil)
        let outcome = try await services.trasher.moveToTrash([fixture.item(kept)])
        #expect(outcome.failed.map(\.reason) == [FileRefusal.protected.text])
        #expect(trash.calls.isEmpty)
    }

    @Test("with the default guard (ProtectedPaths) an ordinary file in the temp home still moves")
    func defaultGuard() async throws {
        let fixture = try FilesFixture()
        let url = try fixture.file("Documents/file.bin")
        let trash = fixture.trash()
        // Only the Spotlight runner and the Trash are replaced; `isProtected` is the default.
        let services = FilesServices(home: fixture.home, runQuery: { _, _, _ in [] }, trash: { try trash.trash($0) })
        let outcome = try await services.trasher.moveToTrash([fixture.item(url)])
        #expect(outcome.moved.map(\.id) == [url.path])
        #expect(!ProtectedPaths.isProtected(url.path))
    }

    @Test("by default the walks enter a folder that holds the app but skip the app; the trasher protects the folder")
    func defaultGuardsSplitWalkAndMove() async throws {
        let fixture = try FilesFixture()
        try fixture.file("Downloads/Build/Mainternance.app/Contents/MacOS/x", bytes: 30000)
        try fixture.file("Downloads/Build/big.bin", bytes: 30000)
        let holder = fixture.path("Downloads/Build")
        let resolved = ProtectedPaths.Resolved(bundlePath: holder + "/Mainternance.app")
        let guards = FilesServices.guards(resolved)
        #expect(!guards.walk(holder))
        #expect(guards.walk(holder + "/Mainternance.app"))
        #expect(guards.move(holder))
        #expect(guards.move(fixture.path("Downloads")))
        let trash = fixture.trash()
        let services = FilesServices(
            home: fixture.home, runQuery: { _, _, _ in [] }, trash: { try trash.trash($0) }, guards: guards
        )
        let scan = try #require(await finishedResult(collectUpdates(services.disk.scan())))
        let downloads = try #require(child("Downloads", of: scan.tree))
        let build = try #require(child("Build", of: downloads))
        #expect(child("big.bin", of: build) != nil)
        #expect(child("Mainternance.app", of: build) == nil)
    }
}
