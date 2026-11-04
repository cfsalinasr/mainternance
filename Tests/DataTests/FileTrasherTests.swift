import Foundation
@testable import MainternanceData
import MainternanceDomain
import Testing

/// Moving single files (search and large-file results) to a fake Trash inside a temp folder. Never the real Trash,
/// home folder or `~/Library`.
@Suite("File trasher")
struct FileTrasherTests {
    @Test("plain files in the home folder move, and only they count as moved")
    func movesPlainFiles() async throws {
        let fixture = try FilesFixture()
        let top = try fixture.file("top.bin", bytes: 5000)
        let deep = try fixture.file("Documents/Taxes/2024/deep.pdf", bytes: 9000)
        let trash = fixture.trash()
        let items = try [fixture.item(top), fixture.item(deep)]
        let outcome = await fixture.trasher(trash).moveToTrash(items)
        #expect(outcome.moved == items)
        #expect(outcome.failed.isEmpty)
        #expect(outcome.movedBytes == items[0].bytes + items[1].bytes)
        #expect(trash.moves.map(\.source.path) == [top.path, deep.path])
        #expect(trash.moves.allSatisfy { fixture.exists($0.destination) })
        #expect(!fixture.exists(top) && !fixture.exists(deep))
    }

    @Test("odd names (spaces, a line break, a leading dash, a bidi override) move as themselves")
    func oddNames() async throws {
        let fixture = try FilesFixture()
        let names = ["two words.txt", "line\nbreak.txt", "-rf.txt", "invoice\u{202E}fdp.exe"]
        let urls = try names.map { try fixture.file("Odd/\($0)") }
        let trash = fixture.trash()
        let items = try urls.map(fixture.item)
        let outcome = await fixture.trasher(trash).moveToTrash(items)
        #expect(outcome.moved.map(\.name) == names)
        #expect(trash.moves.map(\.source.lastPathComponent) == names)
        #expect(!items[3].displayName.contains("\u{202E}"))
        #expect(urls.allSatisfy { !fixture.exists($0) })
    }

    @Test("a file outside the home folder is refused and never offered to the Trash")
    func outsideHome() async throws {
        let fixture = try FilesFixture()
        let outside = try fixture.outside("elsewhere.bin")
        let trash = fixture.trash()
        let item = try fixture.item(outside)
        let outcome = await fixture.trasher(trash).moveToTrash([item])
        #expect(outcome.failed == [FileFailure(file: item, reason: FileRefusal.notInHome.text)])
        #expect(outcome.moved.isEmpty && outcome.movedBytes == 0)
        #expect(trash.calls.isEmpty)
        #expect(fixture.exists(outside))
    }

    @Test("paths that are not plain absolute paths are refused")
    func malformedPaths() async throws {
        let fixture = try FilesFixture()
        let real = try fixture.item(fixture.file("a.txt"))
        let forged = ["a.txt", fixture.home.path + "/", fixture.home.path + "/..", fixture.home.path + "/."]
            .map { FileItem(path: $0, bytes: real.bytes, modified: real.modified, identity: real.identity) }
        let trash = fixture.trash()
        let outcome = await fixture.trasher(trash).moveToTrash(forged)
        #expect(outcome.failed.map(\.reason) == Array(repeating: FileRefusal.notInHome.text, count: 4))
        #expect(trash.calls.isEmpty)
    }

    @Test("files under ~/Library or any dot-folder are refused, whatever the letter case")
    func hiddenPlaces() async throws {
        let fixture = try FilesFixture()
        let urls = try [
            fixture.file("Library/Caches/big.bin"), fixture.file("Library/top.bin"),
            fixture.file(".config/secret.txt"), fixture.file("Projects/app/.git/objects/pack.bin")
        ]
        var items = try urls.map(fixture.item)
        let lower = items[1]
        items.append(lower.renamed(fixture.home.path + "/library/top.bin"))
        let trash = fixture.trash()
        let outcome = await fixture.trasher(trash).moveToTrash(items)
        #expect(outcome.failed.map(\.reason) == Array(repeating: FileRefusal.hiddenPlace.text, count: 5))
        #expect(trash.calls.isEmpty)
        #expect(urls.allSatisfy(fixture.exists))
    }

    @Test("a dot-named file in an ordinary folder is a plain file and moves")
    func dotFileMoves() async throws {
        let fixture = try FilesFixture()
        let url = try fixture.file("Documents/.notes.txt")
        let trash = fixture.trash()
        let outcome = try await fixture.trasher(trash).moveToTrash([fixture.item(url)])
        #expect(outcome.moved.count == 1)
        #expect(!fixture.exists(url))
    }

    @Test("a protected path is refused")
    func protectedPath() async throws {
        let fixture = try FilesFixture()
        let url = try fixture.file("Documents/kept.txt")
        let trash = fixture.trash()
        let seen = Received<String>()
        let trasher = fixture.trasher(trash, isProtected: { seen.add($0)
            return true
        })
        let item = try fixture.item(url)
        let outcome = await trasher.moveToTrash([item])
        #expect(outcome.failed.map(\.reason) == [FileRefusal.protected.text])
        #expect(seen.values == [url.path])
        #expect(trash.calls.isEmpty)
    }

    @Test("a link is refused, whether it was found as a link or a file became one")
    func links() async throws {
        let fixture = try FilesFixture()
        let target = try fixture.file("Documents/target.txt")
        let found = try fixture.link("Documents/found-link", to: target.path)
        let swapped = try fixture.file("Documents/swapped.txt")
        let swappedItem = try fixture.item(swapped)
        try FileManager.default.removeItem(at: swapped)
        try fixture.link("Documents/swapped.txt", to: target.path)
        let trash = fixture.trash()
        let outcome = try await fixture.trasher(trash).moveToTrash([fixture.item(found), swappedItem])
        #expect(outcome.failed.map(\.reason) == [FileRefusal.link.text, FileRefusal.link.text])
        #expect(trash.calls.isEmpty)
        #expect(fixture.exists(target))
    }

    @Test("a folder or a package is refused")
    func foldersAndPackages() async throws {
        let fixture = try FilesFixture()
        let folder = try fixture.folder("Documents/Folder")
        let package = try fixture.folder("Applications/Example.app")
        try fixture.file("Applications/Example.app/Contents/Info.plist")
        let trash = fixture.trash()
        let outcome = try await fixture.trasher(trash).moveToTrash([fixture.item(folder), fixture.item(package)])
        #expect(outcome.failed.map(\.reason) == [FileRefusal.notPlainFile.text, FileRefusal.notPlainFile.text])
        #expect(trash.calls.isEmpty)
    }

    @Test("a file on another volume than the home folder is refused")
    func otherVolume() async throws {
        let fixture = try FilesFixture()
        let mounted = try fixture.file("Volumes-like/mounted.bin")
        let local = try fixture.file("local.bin")
        let trash = fixture.trash()
        let trasher = fixture.trasher(trash, volume: { path, info in
            path == mounted.path ? info.device &+ 1 : info.device
        })
        let outcome = try await trasher.moveToTrash([fixture.item(mounted), fixture.item(local)])
        #expect(outcome.failed.map(\.reason) == [FileRefusal.otherVolume.text])
        #expect(outcome.moved.map(\.id) == [local.path])
        #expect(fixture.exists(mounted))
    }

    @Test("a file changed since it was scanned (replaced, resized, re-dated) is refused")
    func changedSinceScan() async throws {
        let fixture = try FilesFixture()
        let replaced = try fixture.file("replaced.bin", bytes: 6000)
        let grown = try fixture.file("grown.bin", bytes: 6000)
        let redated = try fixture.file("redated.bin", bytes: 6000)
        try fixture.setModified(redated, 1_000_000)
        let items = try [replaced, grown, redated].map(fixture.item)
        try fixture.replace(replaced)
        try fixture.grow(grown)
        try fixture.setModified(redated, 2_000_000)
        let trash = fixture.trash()
        let outcome = await fixture.trasher(trash).moveToTrash(items)
        #expect(outcome.failed.map(\.reason) == Array(repeating: FileRefusal.changed.text, count: 3))
        #expect(trash.calls.isEmpty)
        #expect([replaced, grown, redated].allSatisfy(fixture.exists))
    }

    @Test("a scan result whose recorded size, date or identity does not match is refused")
    func staleRecords() async throws {
        let fixture = try FilesFixture()
        let url = try fixture.file("file.bin", bytes: 6000)
        let item = try fixture.item(url)
        let stale = [
            item.with(bytes: item.bytes + 4096),
            item.with(modified: item.modified.addingTimeInterval(-60)),
            item.with(identity: CleanupEntry.Identity(device: item.identity?.device ?? 0, inode: 1))
        ]
        let trash = fixture.trash()
        let outcome = await fixture.trasher(trash).moveToTrash(stale)
        #expect(outcome.failed.map(\.reason) == Array(repeating: FileRefusal.changed.text, count: 3))
        #expect(trash.calls.isEmpty)
    }

    @Test("a file with no recorded identity cannot be checked and is refused")
    func noIdentity() async throws {
        let fixture = try FilesFixture()
        let item = try fixture.item(fixture.file("file.bin")).with(identity: .some(nil))
        let trash = fixture.trash()
        let outcome = await fixture.trasher(trash).moveToTrash([item])
        #expect(outcome.failed.map(\.reason) == [FileRefusal.unreadable.text])
        #expect(trash.calls.isEmpty)
    }

    @Test("a file that vanished is reported, and the files around it still move")
    func vanishedDoesNotStopOthers() async throws {
        let fixture = try FilesFixture()
        let first = try fixture.file("first.bin")
        let gone = try fixture.file("gone.bin")
        let last = try fixture.file("last.bin")
        let items = try [first, gone, last].map(fixture.item)
        try FileManager.default.removeItem(at: gone)
        let trash = fixture.trash()
        let outcome = await fixture.trasher(trash).moveToTrash(items)
        #expect(outcome.moved == [items[0], items[2]])
        #expect(outcome.failed == [FileFailure(file: items[1], reason: FileRefusal.vanished.text)])
        #expect(outcome.movedBytes == items[0].bytes + items[2].bytes)
    }

    @Test("macOS refusing one move is reported with its reason; the rest continue and only moves count")
    func trashFailure() async throws {
        let fixture = try FilesFixture()
        let refused = try fixture.file("refused.bin", bytes: 7000)
        let fine = try fixture.file("fine.bin", bytes: 3000)
        let trash = fixture.trash(refuses: { $0.lastPathComponent == "refused.bin" })
        let items = try [refused, fine].map(fixture.item)
        let outcome = await fixture.trasher(trash).moveToTrash(items)
        #expect(outcome.moved == [items[1]])
        #expect(outcome.movedBytes == items[1].bytes)
        let reason = try #require(outcome.failed.first?.reason)
        #expect(reason.hasPrefix("macOS could not move it to the Trash: "))
        #expect(trash.calls.count == 2)
    }

    @Test("a link in the folder path is resolved: inside home it moves the real file, out of home it is refused")
    func linkedParents() async throws {
        let fixture = try FilesFixture()
        let inside = try fixture.file("Real/inside.bin")
        try fixture.link("Shortcut", to: fixture.path("Real"))
        let outside = try fixture.outside("away.bin")
        try fixture.link("Away", to: outside.deletingLastPathComponent().path)
        try fixture.link("Lib", to: fixture.folder("Library").path)
        let hidden = try fixture.file("Library/hidden.bin")
        let viaLinks = try [
            fixture.item(inside).renamed(fixture.path("Shortcut/inside.bin")),
            fixture.item(outside).renamed(fixture.path("Away/away.bin")),
            fixture.item(hidden).renamed(fixture.path("Lib/hidden.bin"))
        ]
        let trash = fixture.trash()
        let outcome = await fixture.trasher(trash).moveToTrash(viaLinks)
        #expect(trash.moves.map(\.source.path) == [inside.path])
        #expect(outcome.failed.map(\.reason) == [FileRefusal.notInHome.text, FileRefusal.hiddenPlace.text])
        #expect(fixture.exists(outside) && fixture.exists(hidden))
    }

    @Test("a home folder given through a link still works")
    func linkedHome() async throws {
        let fixture = try FilesFixture()
        let url = try fixture.file("Documents/file.bin")
        let linkedHome = fixture.temp.url.appendingPathComponent("linked-home")
        try FileManager.default.createSymbolicLink(at: linkedHome, withDestinationURL: fixture.home)
        let trash = fixture.trash()
        let trasher = FileTrasher(home: linkedHome, trash: { try trash.trash($0) }, isProtected: { _ in false })
        let outcome = try await trasher.moveToTrash([fixture.item(url)])
        #expect(outcome.moved.count == 1)
        #expect(!fixture.exists(url))
    }

    @Test("the protected-places guard sees the resolved path, never a link spelling")
    func protectedSeesResolved() async throws {
        let fixture = try FilesFixture()
        let url = try fixture.file("Real/file.bin")
        try fixture.link("Shortcut", to: fixture.path("Real"))
        let seen = Received<String>()
        let trash = fixture.trash()
        let trasher = fixture.trasher(trash, isProtected: { seen.add($0)
            return false
        })
        _ = try await trasher.moveToTrash([fixture.item(url).renamed(fixture.path("Shortcut/file.bin"))])
        #expect(seen.values == [url.path])
    }
}

extension FileItem {
    /// The same recorded file under another path spelling.
    func renamed(_ path: String) -> FileItem {
        FileItem(path: path, bytes: bytes, modified: modified, identity: identity)
    }
}
