import Foundation
@testable import MainternanceData
import MainternanceDomain
import Testing

/// Measuring a temp home: only direct children of the fixed folders, sizes without following links.
@Suite("Cleanup measurer")
struct CleanupMeasurerTests {
    @Test("each folder becomes a category of its direct children, largest first")
    func categories() async throws {
        let fixture = try CleanupFixture()
        try fixture.file("small/a.bin", in: fixture.caches, bytes: 10000)
        try fixture.file("big/b.bin", in: fixture.caches, bytes: 300_000)
        try fixture.file("big/nested/deeper/c.bin", in: fixture.caches, bytes: 200_000)
        try fixture.file("app.log", in: fixture.logs, bytes: 5000)
        try fixture.file("Old.dmg", in: fixture.downloads, bytes: 50000, age: 40 * CleanupFixture.day)
        try fixture.file("Build-abc/x.o", in: fixture.derivedData, bytes: 70000)
        let measurement = await fixture.measurer.measure()
        #expect(measurement.categories.map(\.kind) == [.caches, .logs, .installers, .developer])
        #expect(measurement.measuredAt == CleanupFixture.now)
        #expect(measurement.unreadable.isEmpty)
        let caches = try #require(measurement.categories.first)
        #expect(caches.entries.map(\.name) == ["big", "small"])
        #expect(caches.entries.map(\.id) == [
            fixture.caches.appendingPathComponent("big").path, fixture.caches.appendingPathComponent("small").path
        ])
        #expect(isAbout(caches.entries[0].bytes, 500_000))
        #expect(isAbout(caches.entries[1].bytes, 10000))
        #expect(caches.entries.allSatisfy { $0.isDirectory && !$0.isLowerBound })
        let log = try #require(measurement.categories[1].entries.first)
        #expect(log.type == .file)
        #expect(isAbout(log.bytes, 5000))
        #expect(log.modified != nil)
        #expect(measurement.categories[2].entries.map(\.name) == ["Old.dmg"])
        #expect(isAbout(measurement.categories[3].bytes, 70000))
        #expect(measurement.totalBytes == measurement.categories.reduce(0) { $0 + $1.bytes })
    }

    @Test("hidden files count")
    func hiddenFilesCount() async throws {
        let fixture = try CleanupFixture()
        try fixture.file("app/.hidden", in: fixture.caches, bytes: 40000)
        try fixture.file(".dotfolder/x", in: fixture.caches, bytes: 1000)
        let entries = try #require(await fixture.measurer.measure().categories.first).entries
        #expect(entries.map(\.name) == ["app", ".dotfolder"])
        #expect(isAbout(entries[0].bytes, 40000))
    }

    @Test("only old installer files in Downloads count: young, other types, folders and nested files do not")
    func installers() async throws {
        let fixture = try CleanupFixture()
        let old = 31 * CleanupFixture.day
        try fixture.file("A.dmg", in: fixture.downloads, bytes: 20000, age: old)
        try fixture.file("B.PKG", in: fixture.downloads, bytes: 30000, age: old)
        try fixture.file("C.iso", in: fixture.downloads, bytes: 10000, age: old)
        try fixture.file("young.dmg", in: fixture.downloads, age: 29 * CleanupFixture.day)
        try fixture.file("notes.txt", in: fixture.downloads, age: old)
        try fixture.file("archive.zip", in: fixture.downloads, age: old)
        try fixture.file("dmg", in: fixture.downloads, age: old)
        try fixture.file("inner/D.dmg", in: fixture.downloads, age: old)
        let folder = try fixture.folder("Folder.dmg", in: fixture.downloads)
        try FileManager.default.setAttributes(
            [.modificationDate: CleanupFixture.now.addingTimeInterval(-old)], ofItemAtPath: folder.path
        )
        let target = try fixture.file("real.bin", in: fixture.temp.url, age: old)
        try fixture.link("Link.dmg", in: fixture.downloads, to: target.path)
        let installers = await fixture.measurer.measure().categories.first { $0.kind == .installers }
        #expect(installers?.entries.map(\.name) == ["B.PKG", "A.dmg", "C.iso"])
    }

    @Test("the developer category is absent when its folder is absent")
    func developerAbsent() async throws {
        let fixture = try CleanupFixture(developer: false)
        try fixture.file("a/b", in: fixture.caches)
        let measurement = await fixture.measurer.measure()
        #expect(measurement.categories.map(\.kind) == [.caches, .logs, .installers])
        #expect(measurement.unreadable.isEmpty)
    }

    @Test("an empty folder is a category with no entries")
    func emptyFolder() async throws {
        let fixture = try CleanupFixture()
        let logs = await fixture.measurer.measure().categories.first { $0.kind == .logs }
        #expect(logs?.entries.isEmpty == true)
        #expect(logs?.bytes == 0)
    }

    @Test("a symlink entry counts as the link itself, never what it points to")
    func symlinkEntryNotFollowed() async throws {
        let fixture = try CleanupFixture()
        let elsewhere = try fixture.folder("elsewhere", in: fixture.temp.url)
        try fixture.file("huge.bin", in: elsewhere, bytes: 900_000)
        try fixture.link("to-folder", in: fixture.caches, to: elsewhere.path)
        try fixture.link("to-system", in: fixture.caches, to: "/System")
        try fixture.link("to-home", in: fixture.caches, to: fixture.home.path)
        let entries = try #require(await fixture.measurer.measure().categories.first).entries
        #expect(Set(entries.map(\.name)) == ["to-folder", "to-system", "to-home"])
        #expect(entries.allSatisfy { $0.type == .symbolicLink && !$0.isDirectory })
        #expect(entries.allSatisfy { $0.bytes < 100_000 })
    }

    @Test("a symlink inside an entry is not followed for its size")
    func nestedSymlinkNotFollowed() async throws {
        let fixture = try CleanupFixture()
        let elsewhere = try fixture.folder("elsewhere", in: fixture.temp.url)
        try fixture.file("huge.bin", in: elsewhere, bytes: 900_000)
        let app = try fixture.folder("app", in: fixture.caches)
        try fixture.file("small.bin", in: app, bytes: 1000)
        try fixture.link("loop", in: app, to: app.path)
        try fixture.link("out", in: app, to: elsewhere.path)
        let entry = try #require(await fixture.measurer.measure().categories.first?.entries.first)
        #expect(isAbout(entry.bytes, 1000))
        #expect(!entry.isLowerBound)
    }

    @Test("a category folder that is itself a symlink is refused and reported, never followed")
    func symlinkedRootRefused() async throws {
        let fixture = try CleanupFixture()
        let real = try fixture.folder("real-logs", in: fixture.temp.url)
        try fixture.file("x.log", in: real)
        try FileManager.default.removeItem(at: fixture.logs)
        try fixture.link("Logs", in: fixture.logs.deletingLastPathComponent(), to: real.path)
        let measurement = await fixture.measurer.measure()
        #expect(!measurement.categories.contains { $0.kind == .logs })
        #expect(measurement.unreadable == [.logs])
    }

    @Test("an unreadable subfolder makes the entry's size a lower bound")
    func unreadableSubfolder() async throws {
        let fixture = try CleanupFixture()
        try fixture.file("app/ok.bin", in: fixture.caches, bytes: 20000)
        let locked = try fixture.folder("app/locked", in: fixture.caches)
        try fixture.file("secret.bin", in: locked, bytes: 20000)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path) }
        let category = try #require(await fixture.measurer.measure().categories.first)
        let entry = try #require(category.entries.first)
        #expect(entry.isLowerBound)
        #expect(category.isLowerBound)
        #expect(isAbout(entry.bytes, 20000))
    }

    @Test("an unreadable category folder is reported, not shown as empty")
    func unreadableRoot() async throws {
        let fixture = try CleanupFixture()
        try fixture.file("x.log", in: fixture.logs)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: fixture.logs.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fixture.logs.path) }
        let measurement = await fixture.measurer.measure()
        #expect(!measurement.categories.contains { $0.kind == .logs })
        #expect(measurement.unreadable == [.logs])
    }

    @Test("odd names are kept exactly; only the shown name is cleaned")
    func oddNames() async throws {
        let fixture = try CleanupFixture()
        let names = ["with space", "new\nline", "-leading", "rtl\u{202E}cod.exe"]
        for name in names {
            try fixture.file(name, in: fixture.logs, bytes: 1000)
        }
        let entries = try #require(await fixture.measurer.measure().categories.first { $0.kind == .logs }).entries
        #expect(Set(entries.map(\.name)) == Set(names))
        #expect(entries.allSatisfy { $0.id == fixture.logs.appendingPathComponent($0.name).path })
        #expect(Set(entries.map(\.displayName)) == ["with space", "new line", "-leading", "rtlcod.exe"])
    }

    @Test("a cancelled measurement returns promptly with every size marked as a lower bound")
    func cancellation() async throws {
        let fixture = try CleanupFixture()
        for folder in 0 ..< 20 {
            for file in 0 ..< 100 {
                try fixture.file("tree\(folder)/a/b/c/\(file).bin", in: fixture.caches, bytes: 10)
            }
        }
        let measurer = fixture.measurer
        let started = Date()
        let task = Task { () -> CleanupMeasurement in
            withUnsafeCurrentTask { $0?.cancel() }
            return await measurer.measure()
        }
        let measurement = await task.value
        // Generous: a loaded CI runner took 6 to 7 s here twice. A walk that ignored cancellation would run far longer.
        #expect(Date().timeIntervalSince(started) < 30)
        let entries = measurement.categories.flatMap(\.entries)
        #expect(entries.count == 20)
        let allLowerBounds = entries.allSatisfy(\.isLowerBound)
        #expect(allLowerBounds)
        #expect(entries.allSatisfy { $0.bytes < 2000 })
    }

    @Test("each entry carries the device and inode it was measured with")
    func entryIdentity() async throws {
        let fixture = try CleanupFixture()
        let app = try fixture.file("app/a", in: fixture.caches).deletingLastPathComponent()
        let entry = try #require(await fixture.measurer.measure().categories.first?.entries.first)
        let attributes = try FileManager.default.attributesOfItem(atPath: app.path)
        let inode = try #require(attributes[.systemFileNumber] as? NSNumber)
        #expect(entry.identity?.inode == inode.uint64Value)
    }

    @Test("an installer counts as old only when its newest date is: modified, created or added to Downloads")
    func installerNewestDate() async throws {
        let fixture = try CleanupFixture()
        let old = 40 * CleanupFixture.day
        try fixture.file("Old.dmg", in: fixture.downloads, age: old)
        let created = try fixture.file("Created.dmg", in: fixture.downloads, age: old)
        try FileManager.default.setAttributes(
            [.creationDate: CleanupFixture.now.addingTimeInterval(-CleanupFixture.day)], ofItemAtPath: created.path
        )
        let added = try fixture.file("Added.pkg", in: fixture.downloads, age: old)
        let recent = CleanupFixture.now.addingTimeInterval(-2 * CleanupFixture.day)
        let addedPath = added.path
        let rules = fixture.rules(dateAdded: { $0 == addedPath ? recent : nil })
        let installers = await CleanupMeasurer(rules: rules).measure().categories.first { $0.kind == .installers }
        #expect(installers?.entries.map(\.name) == ["Old.dmg"])
    }

    @Test("the real date added is read from the file system: an installer just put in Downloads is not old")
    func realDateAdded() throws {
        let fixture = try CleanupFixture()
        let image = try fixture.file("Fresh.dmg", in: fixture.downloads)
        let longAgo = Date().addingTimeInterval(-90 * CleanupFixture.day)
        try FileManager.default.setAttributes(
            [.modificationDate: longAgo, .creationDate: longAgo], ofItemAtPath: image.path
        )
        let added = try #require(CleanupRules.readDateAdded(image.path))
        #expect(abs(added.timeIntervalSinceNow) < 3600)
        let rules = CleanupRules(roots: fixture.roots, now: { Date() })
        let downloads = try #require(fixture.roots.first { $0.kind == .installers })
        guard case let .found(info) = ItemStat.read(image.path) else {
            Issue.record("the file could not be read")
            return
        }
        #expect(!rules.accepts(path: image.path, info, in: downloads, now: Date()))
    }
}
