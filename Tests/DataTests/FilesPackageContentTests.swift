import Foundation
@testable import MainternanceData
import MainternanceDomain
import Testing

/// A package (an app, a Photos library) counts as one item: nothing inside it is shown by search or moved to the
/// Trash on its own. Temp home, fake Spotlight answer and fake Trash only.
@Suite("Files inside packages")
struct FilesPackageContentTests {
    private func searcher(_ fixture: FilesFixture, _ paths: [String]) -> SpotlightSearcher {
        SpotlightSearcher(home: fixture.home) { _, _, _ in SpotlightAnswer(paths: paths) }
    }

    @Test("a file inside a Photos library, at any depth, is refused and never offered to the Trash")
    func trasherRefusesPackageContents() async throws {
        let fixture = try FilesFixture()
        let deep = try fixture.file("Pictures/X.photoslibrary/originals/A/photo.jpg")
        let direct = try fixture.file("Pictures/X.photoslibrary/database.db")
        let inApp = try fixture.file("Apps/Tool.app/Contents/Resources/data.bin")
        let trash = fixture.trash()
        let items = try [fixture.item(deep), fixture.item(direct), fixture.item(inApp)]
        let outcome = await fixture.trasher(trash).moveToTrash(items)
        #expect(outcome.moved.isEmpty && outcome.movedBytes == 0)
        #expect(outcome.failed.map(\.reason) == Array(repeating: FileRefusal.insidePackage.text, count: 3))
        #expect(trash.calls.isEmpty)
        #expect([deep, direct, inApp].allSatisfy { fixture.exists($0) })
    }

    @Test("a duplicate copy inside a package is refused too")
    func trasherRefusesPackageDuplicates() async throws {
        let fixture = try FilesFixture()
        let group = try fixture.group(["Documents/copy.bin", "Pictures/X.photoslibrary/copy.bin"])
        let trash = fixture.trash()
        let outcome = await fixture.trasher(trash).moveDuplicatesToTrash(group, remove: [group.files[1]])
        #expect(outcome.failed.map(\.reason) == [FileRefusal.insidePackage.text])
        #expect(trash.calls.isEmpty)
    }

    @Test("the trasher asks about every folder from below home down to the file's folder")
    func trasherAsksEveryFolder() async throws {
        let fixture = try FilesFixture()
        let url = try fixture.file("Odd/Bundle-like/inner/file.bin")
        let asked = Received<String>()
        let trash = fixture.trash()
        let trasher = FileTrasher(
            home: fixture.home, trash: { try trash.trash($0) }, isProtected: { _ in false },
            isPackage: { path in
                asked.add(path)
                return path.hasSuffix("/Bundle-like")
            }
        )
        let outcome = try await trasher.moveToTrash([fixture.item(url)])
        #expect(outcome.failed.map(\.reason) == [FileRefusal.insidePackage.text])
        #expect(asked.values == [fixture.path("Odd"), fixture.path("Odd/Bundle-like")])
    }

    @Test("a plain file in an ordinary folder still moves")
    func trasherMovesOrdinaryFile() async throws {
        let fixture = try FilesFixture()
        let url = try fixture.file("Pictures/Holiday/photo.jpg")
        let trash = fixture.trash()
        let outcome = try await fixture.trasher(trash).moveToTrash([fixture.item(url)])
        #expect(outcome.failed.isEmpty)
        #expect(trash.calls.map(\.path) == [url.path])
    }

    @Test("search drops results inside packages and keeps the rest")
    func searcherDropsPackageContents() async throws {
        let fixture = try FilesFixture()
        let keep = try fixture.file("Pictures/Holiday/photo.jpg")
        let paths = try [
            keep.path,
            fixture.file("Pictures/X.photoslibrary/originals/A/photo.jpg").path,
            fixture.file("Pictures/X.photoslibrary/database.db").path,
            fixture.file("Apps/Tool.app/Contents/Resources/photo.jpg").path
        ]
        let result = await searcher(fixture, paths).search(FileSearchQuery(text: "photo"))
        #expect(result.files.map(\.id) == [keep.path])
    }

    @Test("search drops Library results whatever their letter case, like the trasher")
    func searcherLibraryAnyCase() async throws {
        let fixture = try FilesFixture()
        let keep = try fixture.file("Documents/keep.txt")
        let upper = try fixture.file("LIBRARY/Caches/a.txt")
        let result = await searcher(fixture, [keep.path, upper.path]).search(FileSearchQuery(text: "txt"))
        #expect(result.files.map(\.id) == [keep.path])
        let trash = fixture.trash()
        let outcome = try await fixture.trasher(trash).moveToTrash([fixture.item(upper)])
        #expect(outcome.failed.map(\.reason) == [FileRefusal.hiddenPlace.text])
    }

    @Test("the shared rule: names below home, hidden places and packages")
    func homePlaces() {
        #expect(HomePlaces.names(from: "/h", to: "/h") == [])
        #expect(HomePlaces.names(from: "/h", to: "/h/a/b") == ["a", "b"])
        #expect(HomePlaces.names(from: "/h", to: "/hx/a") == nil)
        #expect(HomePlaces.names(from: "/h", to: "/other") == nil)
        #expect(HomePlaces.isHidden(["library", "Caches"]))
        #expect(HomePlaces.isHidden(["Documents", ".git"]))
        #expect(!HomePlaces.isHidden(["Documents", "Library"]))
        #expect(!HomePlaces.isHidden([]))
        #expect(HomePlaces.isInsidePackage(home: "/h", names: ["a", "B.app", "c"]) { $0 == "/h/a/B.app" })
        #expect(!HomePlaces.isInsidePackage(home: "/h", names: []) { _ in true })
    }
}
