import Foundation
@testable import MainternanceData
import MainternanceDomain
import Testing

/// Every test works in its own temp directory, never the real Application Support.
@Suite("Preferences store")
struct PreferencesStoreTests: PreferencesStoreFixture {
    @Test("a missing file loads the defaults and creates nothing")
    func missing() async throws {
        let temp = try TempDirectory()
        #expect(await store(temp).load() == .defaults)
        #expect(!FileManager.default.fileExists(atPath: fileURL(temp).path))
    }

    @Test("save then load round-trips, including the last scheduled run, across store instances")
    func roundTrip() async throws {
        let temp = try TempDirectory()
        await store(temp).save(sample)
        #expect(await store(temp).load() == sample)
    }

    @Test("bad JSON loads the defaults and is moved aside with its bytes intact")
    func damagedIsMovedAside() async throws {
        let temp = try TempDirectory()
        try writeRaw("{ not json", temp)
        #expect(await store(temp).load() == .defaults)
        #expect(try String(contentsOf: asideURL(temp), encoding: .utf8) == "{ not json")
        #expect(!FileManager.default.fileExists(atPath: fileURL(temp).path))
    }

    @Test("a later save writes a fresh file and keeps the aside copy")
    func saveAfterDamageKeepsAside() async throws {
        let temp = try TempDirectory()
        try writeRaw("{ not json", temp)
        let prefs = store(temp)
        _ = await prefs.load()
        await prefs.save(sample)
        #expect(await store(temp).load() == sample)
        #expect(try String(contentsOf: asideURL(temp), encoding: .utf8) == "{ not json")
    }

    @Test("saving over a damaged file that was never loaded moves it aside first")
    func saveWithoutLoadMovesAside() async throws {
        let temp = try TempDirectory()
        try writeRaw("garbage", temp)
        await store(temp).save(sample)
        #expect(try String(contentsOf: asideURL(temp), encoding: .utf8) == "garbage")
        #expect(await store(temp).load() == sample)
    }

    @Test("when the damaged file cannot be moved aside it is not overwritten")
    func unmovableDamagedIsNotOverwritten() async throws {
        let temp = try TempDirectory()
        try writeRaw("garbage", temp)
        let prefs = store(temp)
        prefs.failMovingAside = true
        #expect(await prefs.load() == .defaults)
        await prefs.save(sample)
        #expect(try String(contentsOf: fileURL(temp), encoding: .utf8) == "garbage")
    }

    @Test("an out-of-range schedule is clamped on load")
    func clampedOnLoad() async throws {
        let temp = try TempDirectory()
        try writeRaw("""
        {"launchAtLogin":false,"problemAlerts":true,"schedule":{"hour":-5,"minute":75,"weekday":99},\
        "weeklyDigest":true,"weeklyScanEnabled":true}
        """, temp)
        let loaded = await store(temp).load()
        #expect(loaded.schedule == ScanSchedule(weekday: 7, hour: 0, minute: 59))
        #expect(loaded.weeklyScanEnabled)
        #expect(loaded.lastScheduledRun == nil)
        #expect(!FileManager.default.fileExists(atPath: asideURL(temp).path))
    }

    @Test("a file missing a field keeps every other saved choice and is not treated as damaged")
    func missingFieldKeepsTheRest() async throws {
        let temp = try TempDirectory()
        try writeRaw("""
        {"launchAtLogin":true,"problemAlerts":false,"schedule":{"hour":21,"minute":45,"weekday":5},\
        "weeklyScanEnabled":true}
        """, temp)
        let loaded = await store(temp).load()
        var expected = sample
        expected.weeklyDigest = AppPreferences.defaults.weeklyDigest
        expected.lastScheduledRun = nil
        #expect(loaded == expected)
        #expect(!FileManager.default.fileExists(atPath: asideURL(temp).path))
    }

    @Test("a field of the wrong type still counts as damaged")
    func wrongTypeIsDamaged() async throws {
        let temp = try TempDirectory()
        try writeRaw(#"{"weeklyScanEnabled":"yes"}"#, temp)
        #expect(await store(temp).load() == .defaults)
        #expect(FileManager.default.fileExists(atPath: asideURL(temp).path))
    }

    @Test("the file is private (0600) and replaced atomically, leaving no temp files behind")
    func permissionsAndAtomicity() async throws {
        let temp = try TempDirectory()
        let prefs = store(temp)
        await prefs.save(.defaults)
        let manager = FileManager.default
        let first = try manager.attributesOfItem(atPath: fileURL(temp).path)
        #expect((first[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        await prefs.save(sample)
        let second = try manager.attributesOfItem(atPath: fileURL(temp).path)
        #expect((second[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        // An atomic write renames a new file into place, so the file is a new inode, never a half-written old one.
        let firstInode = (first[.systemFileNumber] as? NSNumber)?.intValue
        let secondInode = (second[.systemFileNumber] as? NSNumber)?.intValue
        #expect(firstInode != secondInode)
        let names = try manager.contentsOfDirectory(atPath: fileURL(temp).deletingLastPathComponent().path)
        #expect(names == ["preferences.json"])
    }

    @Test("concurrent saves leave a readable file holding one of the saved values")
    func concurrentSaves() async throws {
        let temp = try TempDirectory()
        let prefs = store(temp)
        await withTaskGroup(of: Void.self) { group in
            for minute in 0 ..< 40 {
                group.addTask {
                    var value = AppPreferences.defaults
                    value.schedule.minute = minute
                    await prefs.save(value)
                }
            }
        }
        let loaded = await store(temp).load()
        #expect((0 ..< 40).contains(loaded.schedule.minute))
        #expect(!FileManager.default.fileExists(atPath: asideURL(temp).path))
    }

    // MARK: Read-modify-write

    @Test("update applies the change to the saved values and writes the result")
    func updateChangesOnlyWhatItTouches() async throws {
        let temp = try TempDirectory()
        await store(temp).save(sample)
        let result = await store(temp).update { $0.weeklyDigest = false }
        var expected = sample
        expected.weeklyDigest = false
        #expect(result == expected)
        #expect(await store(temp).load() == expected)
    }

    @Test("update on a missing file starts from the defaults")
    func updateWithoutAFile() async throws {
        let temp = try TempDirectory()
        let result = await store(temp).update { $0.weeklyScanEnabled = true }
        var expected = AppPreferences.defaults
        expected.weeklyScanEnabled = true
        #expect(result == expected)
        #expect(await store(temp).load() == expected)
    }

    @Test("update never moves the last scheduled run back, and drops one more than a week ahead")
    func updateKeepsTheLaterRun() async throws {
        let temp = try TempDirectory()
        let prefs = store(temp)
        _ = await prefs.update { $0.lastScheduledRun = Self.now }
        let back = await prefs.update { $0.lastScheduledRun = Self.now.addingTimeInterval(-86400) }
        #expect(back.lastScheduledRun == Self.now)
        try writeRaw(#"{"lastScheduledRun":1802592000}"#, temp) // 30 days after `now`
        let fixed = await prefs.update { $0.lastScheduledRun = Self.now }
        #expect(fixed.lastScheduledRun == Self.now)
    }

    @Test("a slow update holds the lock: a concurrent update waits and both changes survive")
    func updatesAreSerialised() async throws {
        let temp = try TempDirectory()
        let prefs = store(temp)
        let entered = AsyncStream.makeStream(of: Void.self)
        prefs.afterRead = {
            prefs.afterRead = nil
            entered.continuation.yield()
            Thread.sleep(forTimeInterval: 0.2)
        }
        let slow = Task.detached { await prefs.update { $0.lastScheduledRun = Self.now } }
        var waiting = entered.stream.makeAsyncIterator()
        _ = await waiting.next()
        let fast = Task.detached { await prefs.update { $0.problemAlerts = false } }
        _ = await slow.value
        let final = await fast.value
        #expect(final.lastScheduledRun == Self.now)
        #expect(!final.problemAlerts)
        #expect(await store(temp).load() == final)
    }

    @Test("concurrent updates of different fields all survive")
    func concurrentUpdates() async throws {
        let temp = try TempDirectory()
        let prefs = store(temp)
        await withTaskGroup(of: Void.self) { group in
            group.addTask { _ = await prefs.update { $0.lastScheduledRun = Self.now } }
            group.addTask { _ = await prefs.update { $0.weeklyDigest = false } }
            group.addTask { _ = await prefs.update { $0.schedule.weekday = 4 } }
            group.addTask { _ = await prefs.update { $0.launchAtLogin = true } }
        }
        let loaded = await store(temp).load()
        #expect(loaded.lastScheduledRun == Self.now)
        #expect(!loaded.weeklyDigest)
        #expect(loaded.schedule.weekday == 4)
        #expect(loaded.launchAtLogin)
    }

    @Test("update over a damaged file that cannot be moved aside writes nothing")
    func updateOverUnmovableDamaged() async throws {
        let temp = try TempDirectory()
        try writeRaw("garbage", temp)
        let prefs = store(temp)
        prefs.failMovingAside = true
        let result = await prefs.update { $0.weeklyDigest = false }
        #expect(!result.weeklyDigest)
        #expect(try String(contentsOf: fileURL(temp), encoding: .utf8) == "garbage")
    }
}
