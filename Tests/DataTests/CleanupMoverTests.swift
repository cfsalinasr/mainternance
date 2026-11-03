import Foundation
@testable import MainternanceData
import MainternanceDomain
import Synchronization
import Testing

/// Moving measured entries to a fake Trash folder: guarded, one at a time, never a permanent delete.
@Suite("Cleanup mover")
struct CleanupMoverTests {
    private func measured(_ fixture: CleanupFixture) async -> [CleanupEntry] {
        await fixture.measurer.measure().categories.flatMap(\.entries)
    }

    @Test("measured entries move through the Trash closure; the outcome lists them with their sizes")
    func movesThroughTrash() async throws {
        let fixture = try CleanupFixture()
        let app = try fixture.file("app/a.bin", in: fixture.caches, bytes: 30000).deletingLastPathComponent()
        let log = try fixture.file("x.log", in: fixture.logs, bytes: 5000)
        let entries = await measured(fixture)
        let outcome = await fixture.mover().moveToTrash(entries)
        #expect(outcome.moved.map(\.id) == entries.map(\.id))
        #expect(outcome.failed.isEmpty)
        #expect(outcome.movedBytes == entries.reduce(0) { $0 + $1.bytes })
        #expect(!fixture.exists(app))
        #expect(!fixture.exists(log))
        #expect(fixture.trashed("app"))
        #expect(fixture.trashed("x.log"))
        #expect(fixture.trash.trashed.count == 2)
    }

    @Test("the public services measure and move inside the temp home only")
    func services() async throws {
        let fixture = try CleanupFixture()
        try fixture.file("app/a.bin", in: fixture.caches)
        let services = fixture.services
        #expect(await services.estimate.suggestedActions().isEmpty) // nothing until Cleanup measured once
        let entries = await services.scanner.measure().categories.flatMap(\.entries)
        #expect(entries.map(\.name) == ["app"])
        let outcome = await services.mover.moveToTrash(entries)
        #expect(outcome.moved.count == 1)
        #expect(fixture.trashed("app"))
    }

    @Test("a protected path is refused without calling the Trash")
    func protectedRefused() async throws {
        let fixture = try CleanupFixture()
        try fixture.file("keep/a", in: fixture.caches)
        try fixture.file("go/a", in: fixture.caches)
        let entries = await measured(fixture)
        let outcome = await fixture.mover(isProtected: { $0.hasSuffix("/keep") }).moveToTrash(entries)
        #expect(outcome.moved.map(\.name) == ["go"])
        #expect(outcome.failed.map(\.entry.name) == ["keep"])
        #expect(outcome.failed.map(\.reason) == [CleanupRefusal.protected.text])
        #expect(fixture.trash.trashed.map(\.lastPathComponent) == ["go"])
        #expect(fixture.exists(fixture.caches.appendingPathComponent("keep")))
    }

    @Test("a symlink to a system folder is refused by the real guard; the target is never touched")
    func symlinkToSystem() async throws {
        let fixture = try CleanupFixture()
        try fixture.link("sys", in: fixture.caches, to: "/System")
        let outcome = await fixture.mover().moveToTrash(measured(fixture))
        #expect(outcome.moved.isEmpty)
        #expect(outcome.failed.map(\.reason) == [CleanupRefusal.protected.text])
        #expect(fixture.trash.trashed.isEmpty)
    }

    @Test("a symlink entry moves as the link itself; what it points to stays")
    func symlinkMovesAsLink() async throws {
        let fixture = try CleanupFixture()
        let elsewhere = try fixture.folder("elsewhere", in: fixture.temp.url)
        let kept = try fixture.file("keep.bin", in: elsewhere)
        try fixture.link("link", in: fixture.caches, to: elsewhere.path)
        let outcome = await fixture.mover().moveToTrash(measured(fixture))
        #expect(outcome.moved.map(\.name) == ["link"])
        #expect(fixture.exists(kept))
        let trashedLink = fixture.trashFolder.appendingPathComponent("link")
        let type = try FileManager.default.attributesOfItem(atPath: trashedLink.path)[.type] as? FileAttributeType
        #expect(type == .typeSymbolicLink)
    }

    @Test("a path that is not a direct child of a cleanup folder is refused without calling the Trash", arguments: [
        "Library/Caches/app/inner", "Documents/report.pdf", "Library/Caches", "Library/Caches/../Caches2/x",
        "Library/Caches/."
    ])
    func notAChild(relative: String) async throws {
        let fixture = try CleanupFixture()
        let url = fixture.home.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let forged = CleanupEntry(path: url.path, bytes: 1, isLowerBound: false, type: .directory, modified: nil)
        let outcome = await fixture.mover().moveToTrash([forged])
        #expect(outcome.moved.isEmpty)
        #expect(outcome.failed.map(\.reason) == [CleanupRefusal.notInCleanupFolder.text])
        #expect(fixture.trash.trashed.isEmpty)
    }

    @Test("a child reached through a symlinked parent is refused")
    func symlinkedParent() async throws {
        let fixture = try CleanupFixture()
        let real = try fixture.folder("real", in: fixture.temp.url)
        try fixture.file("victim/a", in: real)
        try fixture.link("hop", in: fixture.caches, to: real.path)
        let path = fixture.caches.appendingPathComponent("hop/victim").path
        let forged = CleanupEntry(path: path, bytes: 1, isLowerBound: false, type: .directory, modified: nil)
        let outcome = await fixture.mover().moveToTrash([forged])
        #expect(outcome.failed.map(\.reason) == [CleanupRefusal.notInCleanupFolder.text])
        #expect(fixture.exists(real.appendingPathComponent("victim")))
    }

    @Test("a Downloads file that is not an old installer is refused, even when asked by path")
    func downloadsRuleReapplied() async throws {
        let fixture = try CleanupFixture()
        let document = try fixture.file("thesis.docx", in: fixture.downloads, age: 100 * CleanupFixture.day)
        let forged = CleanupEntry(path: document.path, bytes: 1, isLowerBound: false, type: .file, modified: nil)
        let outcome = await fixture.mover().moveToTrash([forged])
        #expect(outcome.failed.map(\.reason) == [CleanupRefusal.notInCleanupFolder.text])
        #expect(fixture.exists(document))
    }

    @Test("an entry that vanished or changed kind since measuring is refused with a reason")
    func changedSinceMeasured() async throws {
        let fixture = try CleanupFixture()
        let gone = try fixture.file("gone/a", in: fixture.caches).deletingLastPathComponent()
        let swapped = try fixture.file("swapped/a", in: fixture.caches).deletingLastPathComponent()
        let grown = try fixture.file("grown.log", in: fixture.logs)
        let entries = await measured(fixture)
        try FileManager.default.removeItem(at: gone)
        try FileManager.default.removeItem(at: swapped)
        try fixture.link("swapped", in: fixture.caches, to: fixture.home.path)
        try FileManager.default.removeItem(at: grown)
        try fixture.folder("grown.log", in: fixture.logs)
        let outcome = await fixture.mover().moveToTrash(entries)
        #expect(outcome.moved.isEmpty)
        let reasons = Dictionary(uniqueKeysWithValues: outcome.failed.map { ($0.entry.name, $0.reason) })
        #expect(reasons["gone"] == CleanupRefusal.vanished.text)
        #expect(reasons["grown.log"] == CleanupRefusal.changed.text)
        // The swapped-in link points at the home folder: refused (protected or changed), never followed.
        #expect(reasons["swapped"] != nil)
        #expect(fixture.trash.trashed.isEmpty)
        #expect(fixture.exists(fixture.home))
    }

    @Test("an installer that became recent since measuring is refused")
    func installerTouchedSinceMeasured() async throws {
        let fixture = try CleanupFixture()
        let image = try fixture.file("Old.dmg", in: fixture.downloads, age: 40 * CleanupFixture.day)
        let entries = await measured(fixture)
        try FileManager.default.setAttributes([.modificationDate: CleanupFixture.now], ofItemAtPath: image.path)
        let outcome = await fixture.mover().moveToTrash(entries)
        #expect(outcome.failed.map(\.reason) == [CleanupRefusal.notInCleanupFolder.text])
        #expect(fixture.exists(image))
    }

    @Test("one Trash failure does not stop the others and is never counted as moved")
    func oneFailureContinues() async throws {
        let fixture = try CleanupFixture()
        for name in ["a", "busy", "c"] {
            try fixture.file("\(name)/f", in: fixture.caches)
        }
        let entries = await measured(fixture)
        let calls = Mutex<[String]>([])
        let fake = fixture.trash
        let mover = CleanupMover(rules: fixture.rules, trash: { url in
            calls.withLock { $0.append(url.lastPathComponent) }
            if url.lastPathComponent == "busy" {
                throw CocoaError(.fileWriteNoPermission)
            }
            try fake.trash(url)
        }, isProtected: { ProtectedPaths.isProtected($0) })
        let outcome = await mover.moveToTrash(entries)
        #expect(calls.withLock { $0 }.count == 3)
        #expect(Set(outcome.moved.map(\.name)) == ["a", "c"])
        #expect(outcome.failed.map(\.entry.name) == ["busy"])
        let reason = try #require(outcome.failed.first?.reason)
        #expect(reason.hasPrefix("macOS could not move it to the Trash: "))
        #expect(outcome.movedBytes == outcome.moved.reduce(0) { $0 + $1.bytes })
        #expect(fixture.exists(fixture.caches.appendingPathComponent("busy")))
    }

    @Test("entries with odd names move correctly")
    func oddNamesMove() async throws {
        let fixture = try CleanupFixture()
        let names = ["with space", "new\nline", "-leading", "rtl\u{202E}cod.exe"]
        for name in names {
            try fixture.file(name, in: fixture.logs)
        }
        let outcome = await fixture.mover().moveToTrash(measured(fixture))
        #expect(Set(outcome.moved.map(\.name)) == Set(names))
        #expect(names.allSatisfy(fixture.trashed))
    }
}
