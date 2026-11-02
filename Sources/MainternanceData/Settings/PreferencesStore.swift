import Foundation
import MainternanceDomain
import Synchronization

/// Saves the Settings as `preferences.json` (mode `0o600`) in `directory`. Dates are seconds since 1970, keys are
/// sorted.
///
/// A file that cannot be decoded is never overwritten: it is moved aside as `preferences.json.damaged` (replacing
/// an older aside copy) before anything new is written, and loading gives the defaults. If it cannot be moved aside,
/// saving is skipped so the owner's file stays as it was. A schedule out of range is clamped on load; a missing
/// field takes its default (so a field added later never resets the owner's other choices).
/// Reads and writes happen inside one lock, so concurrent saves are serialised and the file is always whole.
public final class PreferencesStore: PreferencesStoring, Sendable {
    private let file: URL
    private let aside: URL
    private let lock = Mutex(())
    private let moveAsideFails = Mutex(false)

    /// Test seam: makes moving a damaged file aside fail.
    var failMovingAside: Bool {
        get { moveAsideFails.withLock { $0 } }
        set { moveAsideFails.withLock { $0 = newValue } }
    }

    public init(directory: URL) {
        file = directory.appendingPathComponent("preferences.json")
        aside = directory.appendingPathComponent("preferences.json.damaged")
    }

    public func load() async -> AppPreferences {
        lock.withLock { _ in
            switch readFile() {
            case .missing:
                return .defaults
            case let .readable(prefs):
                return prefs
            case .damaged:
                _ = moveAside()
                return .defaults
            }
        }
    }

    public func save(_ preferences: AppPreferences) async {
        lock.withLock { _ in
            if case .damaged = readFile(), !moveAside() {
                return
            }
            write(preferences)
        }
    }

    private enum FileState {
        case missing
        case readable(AppPreferences)
        case damaged
    }

    private func readFile() -> FileState {
        guard FileManager.default.fileExists(atPath: file.path) else { return .missing }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        guard let data = try? Data(contentsOf: file),
              var prefs = try? decoder.decode(AppPreferences.self, from: data)
        else { return .damaged }
        prefs.schedule = prefs.schedule.clamped()
        return .readable(prefs)
    }

    /// Returns false when the damaged file is still in place.
    private func moveAside() -> Bool {
        guard !failMovingAside else { return false }
        let manager = FileManager.default
        if manager.fileExists(atPath: aside.path) {
            guard (try? manager.removeItem(at: aside)) != nil else { return false }
        }
        return (try? manager.moveItem(at: file, to: aside)) != nil
    }

    private func write(_ preferences: AppPreferences) {
        let manager = FileManager.default
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(preferences) else { return }
        try? manager.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        guard (try? data.write(to: file, options: .atomic)) != nil else { return }
        try? manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
}
