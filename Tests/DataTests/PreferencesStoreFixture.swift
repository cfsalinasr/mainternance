import Foundation
@testable import MainternanceData
import MainternanceDomain

/// Shared helpers for the preferences store suites. Every test works in its own temp directory, never the real
/// Application Support.
protocol PreferencesStoreFixture {}

extension PreferencesStoreFixture {
    func fileURL(_ temp: TempDirectory) -> URL {
        temp.url.appendingPathComponent("prefs/preferences.json")
    }

    /// The damaged copy made at `now` (unix seconds 1_800_000_000).
    func asideURL(_ temp: TempDirectory) -> URL {
        temp.url.appendingPathComponent("prefs/preferences.json.damaged-1800000000")
    }

    static var now: Date {
        Date(timeIntervalSince1970: 1_800_000_000)
    }

    func store(_ temp: TempDirectory) -> PreferencesStore {
        PreferencesStore(directory: temp.url.appendingPathComponent("prefs", isDirectory: true), now: { Self.now })
    }

    func names(_ temp: TempDirectory) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: fileURL(temp).deletingLastPathComponent().path).sorted()
    }

    func writeRaw(_ text: String, _ temp: TempDirectory) throws {
        try FileManager.default.createDirectory(
            at: fileURL(temp).deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data(text.utf8).write(to: fileURL(temp))
    }

    var sample: AppPreferences {
        var prefs = AppPreferences.defaults
        prefs.launchAtLogin = true
        prefs.weeklyScanEnabled = true
        prefs.schedule = ScanSchedule(weekday: 5, hour: 21, minute: 45)
        prefs.problemAlerts = false
        prefs.lastScheduledRun = Date(timeIntervalSince1970: 1_800_000_000)
        return prefs
    }

    func damagedContents(_ temp: TempDirectory) throws -> Set<String> {
        let folder = fileURL(temp).deletingLastPathComponent()
        return try Set(names(temp).filter { $0.hasPrefix("preferences.json.damaged-") }.map {
            try String(contentsOf: folder.appendingPathComponent($0), encoding: .utf8)
        })
    }
}
