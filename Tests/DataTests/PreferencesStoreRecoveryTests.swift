import Foundation
@testable import MainternanceData
import MainternanceDomain
import Synchronization
import Testing

/// Damaged and unreadable files: what is kept, what is moved, and when writing is skipped.
@Suite("Preferences store recovery")
struct PreferencesStoreRecoveryTests: PreferencesStoreFixture {
    // MARK: Damaged copies are kept, never deleted

    @Test("each damaged file gets its own timestamped copy; an earlier copy is never replaced or deleted")
    func damagedCopiesAreKept() async throws {
        let temp = try TempDirectory()
        let prefs = store(temp)
        try writeRaw("first", temp)
        _ = await prefs.load()
        try writeRaw("second", temp)
        _ = await prefs.load() // same second: a distinct name, not the first copy's
        #expect(try names(temp) == ["preferences.json.damaged-1800000000", "preferences.json.damaged-1800000000-2"])
        #expect(try String(contentsOf: asideURL(temp), encoding: .utf8) == "first")
        let second = asideURL(temp).deletingLastPathComponent()
            .appendingPathComponent("preferences.json.damaged-1800000000-2")
        #expect(try String(contentsOf: second, encoding: .utf8) == "second")
    }

    @Test("once the bounded number of damaged copies exists, the oldest copy goes to the Trash, never deleted")
    func damagedCopiesRotate() async throws {
        let temp = try TempDirectory()
        let trash = FakeTrash(folder: trashFolder(temp))
        let prefs = store(temp, trash: trash)
        let limit = PreferencesStore.maxDamagedCopies
        for index in 0 ..< limit {
            try writeRaw("damaged \(index)", temp)
            _ = await prefs.load()
        }
        try writeRaw("one too many", temp)
        #expect(await prefs.load() == .defaults)
        #expect(!FileManager.default.fileExists(atPath: fileURL(temp).path))
        var expected = Set((1 ..< limit).map { "damaged \($0)" })
        expected.insert("one too many")
        #expect(try damagedContents(temp) == expected) // only the oldest copy ("damaged 0") gave way
        #expect(trash.trashed.map(\.lastPathComponent) == ["preferences.json.damaged-1800000000"])
        let trashedCopy = trashFolder(temp).appendingPathComponent("preferences.json.damaged-1800000000")
        #expect(try String(contentsOf: trashedCopy, encoding: .utf8) == "damaged 0") // in the Trash, not gone
        // Saving works again instead of being skipped forever.
        await prefs.save(sample)
        #expect(await store(temp).load() == sample)
        // The next rotation replaces the next oldest, not the copy just made.
        try writeRaw("and another", temp)
        _ = await prefs.load()
        expected.remove("damaged 1")
        expected.insert("and another")
        #expect(try damagedContents(temp) == expected)
        #expect(try names(temp).count(where: { $0.hasPrefix("preferences.json.damaged-") }) == limit)
        #expect(trash.trashed.map(\.lastPathComponent)
            == ["preferences.json.damaged-1800000000", "preferences.json.damaged-1800000000-2"])
    }

    @Test("when the oldest copy cannot go to the Trash, the damaged file stays in place and nothing is written")
    func trashFailureKeepsDamagedFile() async throws {
        let temp = try TempDirectory()
        let trash = FakeTrash(folder: trashFolder(temp))
        let limit = PreferencesStore.maxDamagedCopies
        for index in 0 ..< limit {
            try writeRaw("damaged \(index)", temp)
            _ = await store(temp, trash: trash).load()
        }
        let refusing = FakeTrash(folder: trashFolder(temp), fails: true)
        let prefs = store(temp, trash: refusing)
        let before = try names(temp)
        try writeRaw("one too many", temp)
        #expect(await prefs.load() == .defaults)
        await prefs.save(sample)
        _ = await prefs.update { $0.launchAtLogin = true }
        #expect(try String(contentsOf: fileURL(temp), encoding: .utf8) == "one too many")
        #expect(try names(temp) == (before + ["preferences.json"]).sorted())
        #expect(try damagedContents(temp) == Set((0 ..< limit).map { "damaged \($0)" }))
        #expect(refusing.trashed.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: trashFolder(temp).path))
    }

    @Test("a file that only looks like a damaged copy is never counted, rotated or sent to the Trash")
    func strayLookalikesAreIgnored() async throws {
        let temp = try TempDirectory()
        let trash = FakeTrash(folder: trashFolder(temp))
        let strays = [
            "preferences.json.damaged-backup", "preferences.json.damaged-+5", "preferences.json.damaged-1-2-3",
            "preferences.json.damaged-12-1", "preferences.json.damaged-12-x", "preferences.json.damaged-"
        ]
        for stray in strays {
            try writeBeside(stray, "keep \(stray)", temp)
        }
        let prefs = store(temp, trash: trash)
        let limit = PreferencesStore.maxDamagedCopies
        for index in 0 ..< limit {
            try writeRaw("damaged \(index)", temp)
            _ = await prefs.load()
        }
        #expect(trash.trashed.isEmpty) // the look-alikes did not count towards the limit
        try writeRaw("one too many", temp)
        _ = await prefs.load()
        #expect(trash.trashed.map(\.lastPathComponent) == ["preferences.json.damaged-1800000000"])
        let folder = fileURL(temp).deletingLastPathComponent()
        for stray in strays {
            let contents = try String(contentsOf: folder.appendingPathComponent(stray), encoding: .utf8)
            #expect(contents == "keep \(stray)")
        }
    }

    @Test("a protected path is never sent to the Trash: the damaged file stays and nothing is written")
    func protectedOldestCopyStaysPut() async throws {
        let temp = try TempDirectory()
        let trash = FakeTrash(folder: trashFolder(temp))
        let limit = PreferencesStore.maxDamagedCopies
        for index in 0 ..< limit {
            try writeRaw("damaged \(index)", temp)
            _ = await store(temp, trash: trash).load()
        }
        let asked = Mutex<[String]>([])
        let prefs = store(temp, trash: trash) { path in
            asked.withLock { $0.append(path) }
            return true
        }
        let before = try names(temp)
        try writeRaw("one too many", temp)
        #expect(await prefs.load() == .defaults)
        await prefs.save(sample)
        #expect(asked.withLock { $0 }.first == asideURL(temp).path) // the whole path of the oldest copy
        #expect(trash.trashed.isEmpty)
        #expect(try String(contentsOf: fileURL(temp), encoding: .utf8) == "one too many")
        #expect(try names(temp) == (before + ["preferences.json"]).sorted())
    }

    // MARK: A file that exists but cannot be read is not damaged

    @Test("a file that cannot be read loads the defaults, is not moved aside, and blocks writes until a load succeeds")
    func unreadableFileIsLeftAlone() async throws {
        let temp = try TempDirectory()
        await store(temp).save(sample)
        let path = fileURL(temp).path
        let manager = FileManager.default
        try manager.setAttributes([.posixPermissions: 0o000], ofItemAtPath: path)
        defer { try? manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path) }
        let prefs = store(temp)
        #expect(await prefs.load() == .defaults)
        await prefs.save(.defaults)
        _ = await prefs.update { $0.weeklyDigest = false }
        #expect(try names(temp) == ["preferences.json"]) // nothing moved aside
        // The read error passes; until a load succeeds, the defaults shown must not be written over the real file.
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
        await prefs.save(.defaults)
        _ = await prefs.update { $0.launchAtLogin = false }
        #expect(await store(temp).load() == sample)
        #expect(await prefs.load() == sample)
        await prefs.save(.defaults)
        #expect(await store(temp).load() == .defaults) // writing resumes after a good load
    }

    @Test("a directory in place of the file is unreadable, not damaged: nothing is moved or written")
    func directoryInPlaceIsLeftAlone() async throws {
        let temp = try TempDirectory()
        try FileManager.default.createDirectory(at: fileURL(temp), withIntermediateDirectories: true)
        let prefs = store(temp)
        #expect(await prefs.load() == .defaults)
        await prefs.save(sample)
        let result = await prefs.update { $0.weeklyDigest = false }
        #expect(!result.weeklyDigest)
        #expect(try names(temp) == ["preferences.json"])
        var isDirectory: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: fileURL(temp).path, isDirectory: &isDirectory))
        #expect(isDirectory.boolValue)
    }
}
