import Foundation
@testable import MainternanceData
import MainternanceDomain
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

    @Test("once the bounded number of damaged copies exists, the newest damaged file replaces the oldest copy")
    func damagedCopiesRotate() async throws {
        let temp = try TempDirectory()
        let prefs = store(temp)
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
