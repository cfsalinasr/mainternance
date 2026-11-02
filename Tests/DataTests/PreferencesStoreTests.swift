import Foundation
@testable import MainternanceData
import MainternanceDomain
import Testing

/// Every test works in its own temp directory, never the real Application Support.
@Suite("Preferences store")
struct PreferencesStoreTests {
    private func fileURL(_ temp: TempDirectory) -> URL {
        temp.url.appendingPathComponent("prefs/preferences.json")
    }

    private func asideURL(_ temp: TempDirectory) -> URL {
        temp.url.appendingPathComponent("prefs/preferences.json.damaged")
    }

    private func store(_ temp: TempDirectory) -> PreferencesStore {
        PreferencesStore(directory: temp.url.appendingPathComponent("prefs", isDirectory: true))
    }

    private func writeRaw(_ text: String, _ temp: TempDirectory) throws {
        try FileManager.default.createDirectory(
            at: fileURL(temp).deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data(text.utf8).write(to: fileURL(temp))
    }

    private var sample: AppPreferences {
        var prefs = AppPreferences.defaults
        prefs.launchAtLogin = true
        prefs.weeklyScanEnabled = true
        prefs.schedule = ScanSchedule(weekday: 5, hour: 21, minute: 45)
        prefs.problemAlerts = false
        prefs.lastScheduledRun = Date(timeIntervalSince1970: 1_800_000_000)
        return prefs
    }

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
}
