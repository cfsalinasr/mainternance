import Foundation
@testable import MainternanceData
import MainternanceDomain
import Synchronization

/// Stands in for the Trash: records each URL it is given and moves the item into `folder` (a temp folder), or
/// throws when `fails` is set, leaving the item where it is.
final class FakeTrash: Sendable {
    struct Refused: Error {}

    let folder: URL
    private let state = Mutex<(trashed: [URL], fails: Bool)>(([], false))

    init(folder: URL, fails: Bool = false) {
        self.folder = folder
        state.withLock { $0.fails = fails }
    }

    var trashed: [URL] {
        state.withLock { $0.trashed }
    }

    func trash(_ url: URL) throws {
        try state.withLock { current in
            guard !current.fails else { throw Refused() }
            let manager = FileManager.default
            try manager.createDirectory(at: folder, withIntermediateDirectories: true)
            try manager.moveItem(at: url, to: folder.appendingPathComponent(url.lastPathComponent))
            current.trashed.append(url)
        }
    }
}

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

    /// Never the real Trash: by default a trashed item moves into `<temp>/trash`.
    func store(_ temp: TempDirectory, trash: FakeTrash? = nil) -> PreferencesStore {
        let fake = trash ?? FakeTrash(folder: trashFolder(temp))
        return PreferencesStore(
            directory: temp.url.appendingPathComponent("prefs", isDirectory: true), now: { Self.now },
            trash: { try fake.trash($0) }
        )
    }

    func trashFolder(_ temp: TempDirectory) -> URL {
        temp.url.appendingPathComponent("trash", isDirectory: true)
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
