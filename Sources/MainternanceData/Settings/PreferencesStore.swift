import Foundation
import MainternanceDomain
import Synchronization

/// Saves the Settings as `preferences.json` (mode `0o600`) in `directory`. Dates are seconds since 1970, keys are
/// sorted.
///
/// A file that cannot be decoded is never overwritten and never deleted: it is moved aside as
/// `preferences.json.damaged-<unix seconds>` (with `-2`, `-3`, ... when that name is taken) before anything new is
/// written, and loading gives the defaults. At most `maxDamagedCopies` such copies are made; after that (or if the
/// move fails) the damaged file stays where it is and saving is skipped, so the owner's file stays as it was. A
/// schedule out of range is clamped on load; a missing field takes its default (so a field added later never resets
/// the owner's other choices).
/// Reads and writes happen inside one lock, so concurrent saves and updates are serialised and the file is always
/// whole; `update` reads, changes and writes inside that one lock.
public final class PreferencesStore: PreferencesStoring, Sendable {
    /// How many damaged copies may pile up beside the file. They are kept for the owner; nothing removes them.
    static let maxDamagedCopies = 5
    private static let damagedPrefix = "preferences.json.damaged-"

    private let directory: URL
    private let file: URL
    private let now: @Sendable () -> Date
    private let lock = Mutex(())
    private let moveAsideFails = Mutex(false)
    private let afterReadHook = Mutex<(@Sendable () -> Void)?>(nil)

    /// Test seam: makes moving a damaged file aside fail.
    var failMovingAside: Bool {
        get { moveAsideFails.withLock { $0 } }
        set { moveAsideFails.withLock { $0 = newValue } }
    }

    /// Test seam: runs inside the lock, after `update` read the file and before it writes.
    var afterRead: (@Sendable () -> Void)? {
        get { afterReadHook.withLock { $0 } }
        set { afterReadHook.withLock { $0 = newValue } }
    }

    /// `now` names damaged copies and judges a recorded run that lies too far ahead.
    public init(directory: URL, now: @escaping @Sendable () -> Date = Date.init) {
        self.directory = directory
        file = directory.appendingPathComponent("preferences.json")
        self.now = now
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

    public func update(_ change: @Sendable (inout AppPreferences) -> Void) async -> AppPreferences {
        lock.withLock { _ in
            var base = AppPreferences.defaults
            var writable = true
            switch readFile() {
            case .missing:
                break
            case let .readable(prefs):
                base = prefs
            case .damaged:
                writable = moveAside()
            }
            afterRead?()
            let next = base.updated(now: now(), change)
            if writable {
                write(next)
            }
            return next
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

    /// Returns false when the damaged file is still in place. Never replaces or deletes anything: the move fails
    /// rather than overwrite, and a taken name gets a counter.
    private func moveAside() -> Bool {
        guard !failMovingAside else { return false }
        let manager = FileManager.default
        let existing = (try? manager.contentsOfDirectory(atPath: directory.path)) ?? []
        guard existing.count(where: { $0.hasPrefix(Self.damagedPrefix) }) < Self.maxDamagedCopies else {
            return false
        }
        let stamp = "\(Self.damagedPrefix)\(Int(now().timeIntervalSince1970))"
        for attempt in 1 ... Self.maxDamagedCopies + 1 {
            let name = attempt == 1 ? stamp : "\(stamp)-\(attempt)"
            let aside = directory.appendingPathComponent(name)
            // `moveItem` refuses an existing destination, so an earlier copy is never overwritten.
            guard !manager.fileExists(atPath: aside.path) else { continue }
            return (try? manager.moveItem(at: file, to: aside)) != nil
        }
        return false
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
