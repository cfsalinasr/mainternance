import Foundation
@testable import MainternanceData
import MainternanceDomain
import Testing

/// A folder that holds the running app (for example `~/Library/Caches/mainternance`, where `scripts/build-app.sh`
/// puts `dist/Mainternance.app`) must never be listed or moved: the app would go to the Trash with it. The app path
/// is injected; the real bundle is never used here.
@Suite("Folders that hold the running app")
struct HoldsAppTests {
    /// A fake app bundle inside `~/Library/Caches/mainternance/dist` of the temp home.
    private static func fakeBundle(in fixture: CleanupFixture) throws -> URL {
        let bundle = fixture.caches.appendingPathComponent("mainternance/dist/Mainternance.app", isDirectory: true)
        try fixture.file("Contents/MacOS/Mainternance", in: bundle, bytes: 2000)
        return bundle
    }

    @Test("ProtectedPaths protects every folder above the app bundle, and says it holds the app")
    func ancestorsProtected() throws {
        let fixture = try CleanupFixture()
        let bundle = try Self.fakeBundle(in: fixture)
        let resolved = ProtectedPaths.Resolved(bundlePath: bundle.path)
        let holder = fixture.caches.appendingPathComponent("mainternance").path
        #expect(resolved.holdsApp(holder))
        #expect(resolved.holdsApp(holder + "/dist"))
        #expect(resolved.isProtected(holder))
        #expect(resolved.isProtected(fixture.caches.path))
        // The bundle itself is protected, but it does not "hold" the app: it is the app.
        #expect(!resolved.holdsApp(bundle.path))
        #expect(resolved.isProtected(bundle.path))
        // A sibling is not protected, nor a name that only starts the same way.
        let sibling = fixture.caches.appendingPathComponent("mainternance-other").path
        #expect(!resolved.holdsApp(sibling))
        #expect(!resolved.isProtected(sibling))
        // A walk still enters a folder that holds the app; the app itself is still refused.
        #expect(!resolved.isWithinProtected(holder))
        #expect(resolved.isWithinProtected(bundle.path))
    }

    @Test("folders that hold an extra protected folder are protected too")
    func extraAncestorsProtected() throws {
        let temp = try TempDirectory()
        let vault = temp.url.appendingPathComponent("Support/Mainternance/Quarantine", isDirectory: true)
        try FileManager.default.createDirectory(at: vault, withIntermediateDirectories: true)
        let support = temp.url.appendingPathComponent("Support").path
        #expect(ProtectedPaths.isProtected(support, including: [vault]))
        #expect(ProtectedPaths.isProtected(support + "/Mainternance", including: [vault]))
        #expect(!ProtectedPaths.isProtected(support + "/Other", including: [vault]))
        #expect(!ProtectedPaths.Resolved(including: [vault]).isWithinProtected(support))
    }

    @Test("Cleanup does not list a cache folder that holds the running app")
    func measurerSkipsHolder() async throws {
        let fixture = try CleanupFixture()
        let bundle = try Self.fakeBundle(in: fixture)
        try fixture.file("other/a.bin", in: fixture.caches)
        let resolved = ProtectedPaths.Resolved(bundlePath: bundle.path)
        let rules = CleanupRules(
            roots: fixture.roots, now: { CleanupFixture.now }, dateAdded: { _ in nil },
            holdsApp: { resolved.holdsApp($0) }
        )
        let names = await CleanupMeasurer(rules: rules).measure().categories.flatMap(\.entries).map(\.name)
        #expect(names == ["other"])
    }

    @Test("Cleanup refuses to move a folder that holds the running app, with its own reason")
    func moverRefusesHolder() async throws {
        let fixture = try CleanupFixture()
        let bundle = try Self.fakeBundle(in: fixture)
        // Measured without the check (as an older list might have been), so the entry reaches the mover.
        let entries = await fixture.measurer.measure().categories.flatMap(\.entries)
        #expect(entries.map(\.name) == ["mainternance"])
        let resolved = ProtectedPaths.Resolved(bundlePath: bundle.path)
        let rules = CleanupRules(
            roots: fixture.roots, now: { CleanupFixture.now }, dateAdded: { _ in nil },
            holdsApp: { resolved.holdsApp($0) }
        )
        let fake = fixture.trash
        let mover = CleanupMover(rules: rules, trash: { try fake.trash($0) }, isProtected: { _ in false })
        let outcome = await mover.moveToTrash(entries)
        #expect(outcome.moved.isEmpty)
        #expect(outcome.failed.map(\.reason) == ["It holds Mainternance itself."])
        #expect(CleanupRefusal.holdsApp.text == "It holds Mainternance itself.")
        #expect(fixture.trash.trashed.isEmpty)
        #expect(fixture.exists(bundle))
    }

    @Test("Cleanup refuses an entry with no recorded identity, like the other movers")
    func moverRefusesUnknownIdentity() async throws {
        let fixture = try CleanupFixture()
        let folder = try fixture.file("app/a.bin", in: fixture.caches).deletingLastPathComponent()
        let measured = try #require(await fixture.measurer.measure().categories.first?.entries.first)
        #expect(measured.identity != nil)
        let forged = CleanupEntry(
            path: measured.id, bytes: measured.bytes, isLowerBound: false, type: measured.type,
            modified: measured.modified
        )
        let outcome = await fixture.mover().moveToTrash([forged])
        #expect(outcome.moved.isEmpty)
        #expect(outcome.failed.map(\.reason) == [CleanupRefusal.unreadable.text])
        #expect(fixture.trash.trashed.isEmpty)
        #expect(fixture.exists(folder))
    }

    @Test("the Uninstaller refuses a leftover folder that holds the running app, with its own reason")
    func uninstallerRefusesHolder() async throws {
        let fixture = try UninstallerFixture()
        try fixture.library("Caches/holder/dist/Mainternance.app/Contents/MacOS/x", bytes: 10)
        try fixture.library("Caches/go/a.bin", bytes: 10)
        let bundle = fixture.library.appendingPathComponent("Caches/holder/dist/Mainternance.app").path
        let resolved = ProtectedPaths.Resolved(bundlePath: bundle)
        let trash = fixture.trash()
        let mover = AppMover(
            home: fixture.home, applicationFolders: [fixture.applications], isRunning: { _ in false },
            trash: { try trash.trash($0) }, isProtected: { _ in false }, holdsApp: { resolved.holdsApp($0) }
        )
        let outcome = try await fixture.moveLeftovers(
            [fixture.leftover("Caches/holder"), fixture.leftover("Caches/go")], trash, using: mover
        )
        #expect(outcome.failedLeftovers.map(\.reason) == ["It holds Mainternance itself."])
        #expect(UninstallRefusal.holdsApp.text == "It holds Mainternance itself.")
        #expect(outcome.movedLeftovers.map(\.name) == ["go"])
        #expect(trash.moves.map(\.source.lastPathComponent) == ["go"])
    }
}

/// Hidden (dot) files follow Search's rule everywhere: Large files and Duplicates never list them.
@Suite("Hidden files in Large files and Duplicates")
struct HiddenFilesTests {
    @Test("a big dot-file is not in Large files, while the same file without the dot is")
    func largeFilesSkipDotFiles() throws {
        let fixture = try FilesFixture()
        try fixture.file("Movies/.render-cache.mov", bytes: 300_000)
        try fixture.file("Movies/render.mov", bytes: 300_000)
        let result = fixture.scanner(threshold: 40000).run(shouldStop: { false }, progress: { _ in })
        #expect(result.largest.map(\.name) == ["render.mov"])
    }

    @Test("a dot-file is never offered as a duplicate")
    func duplicatesSkipDotFiles() throws {
        let fixture = try FilesFixture()
        try fixture.write("Documents/.b.pdf", pattern(5000))
        try fixture.write("Downloads/b.pdf", pattern(5000))
        try fixture.write("Desktop/b copy.pdf", pattern(5000))
        let run = fixture.findDuplicates()
        let files = run.groups.flatMap(\.files).map(\.id)
        #expect(files == [fixture.path("Desktop/b copy.pdf"), fixture.path("Downloads/b.pdf")])
    }

    @Test("a hidden package folder (a dot-name) is never reported")
    func hiddenPackageSkipped() throws {
        let fixture = try FilesFixture()
        try fixture.file("Applications/.Hidden.app/Contents/x", bytes: 5000)
        try fixture.file("Applications/Shown.app/Contents/x", bytes: 5000)
        let record = fixture.walk()
        #expect(record.paths == [fixture.path("Applications/Shown.app")])
    }
}
