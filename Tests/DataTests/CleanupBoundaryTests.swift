import Foundation
@testable import MainternanceData
import MainternanceDomain
import Testing

/// Where a Cleanup folder may lead: never out of the home folder through a linked folder on the way to it, and never
/// onto another volume through a folder mounted inside it.
@Suite("Cleanup boundaries")
struct CleanupBoundaryTests {
    /// Moves `folder` (inside the temp home) to `elsewhere` in the temp folder and leaves a link in its place.
    private func replaceWithLink(_ folder: URL, in fixture: CleanupFixture, elsewhere: String) throws -> URL {
        let target = fixture.temp.url.appendingPathComponent(elsewhere, isDirectory: true)
        try FileManager.default.moveItem(at: folder, to: target)
        try fixture.link(folder.lastPathComponent, in: folder.deletingLastPathComponent(), to: target.path)
        return target
    }

    @Test("a linked Library folder makes every folder under it unusable; Downloads still counts")
    func linkedLibrary() async throws {
        let fixture = try CleanupFixture()
        try fixture.file("app/a", in: fixture.caches)
        try fixture.file("x.log", in: fixture.logs)
        try fixture.file("Build/x.o", in: fixture.derivedData)
        try fixture.file("Old.dmg", in: fixture.downloads, age: 40 * CleanupFixture.day)
        let library = fixture.home.appendingPathComponent("Library", isDirectory: true)
        let outside = try replaceWithLink(library, in: fixture, elsewhere: "outside-library")
        let measurement = await fixture.measurer.measure()
        #expect(measurement.categories.map(\.kind) == [.installers])
        #expect(measurement.unreadable == [.caches, .logs, .developer])
        let forged = CleanupEntry(
            path: fixture.caches.appendingPathComponent("app").path, bytes: 1, isLowerBound: false,
            type: .directory, modified: nil
        )
        let outcome = await fixture.mover().moveToTrash([forged])
        #expect(outcome.failed.map(\.reason) == [CleanupRefusal.notInCleanupFolder.text])
        #expect(fixture.trash.trashed.isEmpty)
        #expect(fixture.exists(outside.appendingPathComponent("Caches/app")))
    }

    @Test("a linked folder between Library and DerivedData makes the developer folder unusable")
    func linkedDeveloperAncestor() async throws {
        let fixture = try CleanupFixture()
        try fixture.file("Build/x.o", in: fixture.derivedData)
        try fixture.file("app/a", in: fixture.caches)
        let developer = fixture.home.appendingPathComponent("Library/Developer", isDirectory: true)
        _ = try replaceWithLink(developer, in: fixture, elsewhere: "outside-developer")
        let measurement = await fixture.measurer.measure()
        #expect(measurement.categories.map(\.kind) == [.caches, .logs, .installers])
        #expect(measurement.unreadable == [.developer])
    }

    @Test("a linked Downloads folder is unusable and nothing in it moves")
    func linkedDownloads() async throws {
        let fixture = try CleanupFixture()
        let image = try fixture.file("Old.dmg", in: fixture.downloads, age: 40 * CleanupFixture.day)
        let entries = await fixture.measurer.measure().categories.flatMap(\.entries)
        let outside = try replaceWithLink(fixture.downloads, in: fixture, elsewhere: "outside-downloads")
        let measurement = await fixture.measurer.measure()
        #expect(!measurement.categories.contains { $0.kind == .installers })
        #expect(measurement.unreadable == [.installers])
        let outcome = await fixture.mover().moveToTrash(entries)
        #expect(outcome.moved.isEmpty)
        #expect(fixture.exists(outside.appendingPathComponent(image.lastPathComponent)))
    }

    @Test("links at or above the home folder are fine: a temp home and a home reached through a link both work")
    func linksAboveHomeAllowed() async throws {
        let fixture = try CleanupFixture()
        try fixture.file("app/a", in: fixture.caches)
        let all: [CleanupKind] = [.caches, .logs, .installers, .developer]
        let direct = await fixture.measurer.measure()
        #expect(direct.categories.map(\.kind) == all)
        #expect(direct.unreadable.isEmpty)
        let linkedHome = try fixture.link("home-link", in: fixture.temp.url, to: fixture.home.path)
        let rules = CleanupRules(roots: CleanupRoots.standard(home: linkedHome), now: { CleanupFixture.now })
        let measurement = await CleanupMeasurer(rules: rules).measure()
        #expect(measurement.categories.map(\.kind) == all)
        #expect(measurement.unreadable.isEmpty)
        let fake = fixture.trash
        let mover = CleanupMover(rules: rules, trash: { try fake.trash($0) }, isProtected: { _ in false })
        let outcome = await mover.moveToTrash(measurement.categories.flatMap(\.entries))
        #expect(outcome.moved.map(\.name) == ["app"])
    }

    @Test("a folder on another volume inside a Cleanup folder is not measured or listed")
    func otherVolumeNotMeasured() async throws {
        let fixture = try CleanupFixture()
        try fixture.file("mounted/big.bin", in: fixture.caches, bytes: 300_000)
        try fixture.file("local/a.bin", in: fixture.caches)
        let rules = fixture.rules(volume: Self.mountedElsewhere)
        let caches = try #require(await CleanupMeasurer(rules: rules).measure().categories.first)
        #expect(caches.entries.map(\.name) == ["local"])
    }

    @Test("a folder that is on another volume when the move runs is refused with its own reason")
    func otherVolumeRefused() async throws {
        let fixture = try CleanupFixture()
        try fixture.file("mounted/big.bin", in: fixture.caches)
        try fixture.file("local/a.bin", in: fixture.caches)
        let entries = await fixture.measurer.measure().categories.flatMap(\.entries)
        let fake = fixture.trash
        let mover = CleanupMover(
            rules: fixture.rules(volume: Self.mountedElsewhere), trash: { try fake.trash($0) },
            isProtected: { ProtectedPaths.isProtected($0) }
        )
        let outcome = await mover.moveToTrash(entries)
        #expect(outcome.moved.map(\.name) == ["local"])
        #expect(outcome.failed.map(\.entry.name) == ["mounted"])
        #expect(outcome.failed.map(\.reason) == [CleanupRefusal.otherVolume.text])
        #expect(fixture.exists(fixture.caches.appendingPathComponent("mounted")))
    }

    /// Pretends that anything named `mounted` sits on another volume (tests cannot mount one).
    private static let mountedElsewhere: @Sendable (String, ItemStat) -> Int32 = { path, info in
        (path as NSString).lastPathComponent == "mounted" ? info.device &+ 1 : info.device
    }
}
