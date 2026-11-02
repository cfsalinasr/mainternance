import Foundation
import MainternanceDomain
import Synchronization

/// Saves the Settings as `preferences.json` (mode `0o600`) in `directory`. Dates are seconds since 1970, keys are
/// sorted.
///
/// A file that cannot be decoded is never overwritten and never deleted: it is moved aside as
/// `preferences.json.damaged-<unix seconds>` (with `-2`, `-3`, ... when that name is taken) before anything new is
/// written, and loading gives the defaults. At most `maxDamagedCopies` such copies are kept beside the file: once that
/// many exist, the oldest copy is moved to the Trash (never permanently deleted) and the newest damaged file takes a
/// fresh name, so saving keeps working. If the oldest copy cannot be moved to the Trash, or moving aside fails, the
/// damaged file stays where it is and saving is skipped.
/// A file that exists but cannot be READ (no permission, a directory in its place, an I/O error) is not damaged: it is
/// left alone, loading gives the defaults, and nothing is saved until a later load reads the file (or finds it gone),
/// so defaults shown after a passing read error are never written over the owner's choices.
/// A schedule out of range is clamped on load; a missing field takes its default (so a field added later never resets
/// the owner's other choices).
/// Reads and writes happen inside one lock, so concurrent saves and updates are serialised and the file is always
/// whole; `update` reads, changes and writes inside that one lock.
public final class PreferencesStore: PreferencesStoring, Sendable {
    /// How many damaged copies may sit beside the file. Beyond that the oldest goes to the Trash.
    static let maxDamagedCopies = 5
    private static let damagedPrefix = "preferences.json.damaged-"

    private let directory: URL
    private let file: URL
    private let now: @Sendable () -> Date
    private let trash: @Sendable (URL) throws -> Void
    /// True from a read that failed until a load reads the file (or finds it missing or damaged): writes are skipped.
    private let lock = Mutex(false)
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

    /// `now` names damaged copies and judges a recorded run that lies too far ahead. `trash` moves the oldest damaged
    /// copy to the Trash (tests pass a fake so they never touch the real Trash).
    public init(
        directory: URL,
        now: @escaping @Sendable () -> Date = Date.init,
        trash: @escaping @Sendable (URL) throws -> Void = PreferencesStore.moveToTrash
    ) {
        self.directory = directory
        file = directory.appendingPathComponent("preferences.json")
        self.now = now
        self.trash = trash
    }

    /// The real Trash: the item can be put back from Finder.
    public static func moveToTrash(_ url: URL) throws {
        try FileManager.default.trashItem(at: url, resultingItemURL: nil)
    }

    public func load() async -> AppPreferences {
        lock.withLock { unreadable in
            let state = readFile()
            if case .unreadable = state {
                unreadable = true
                return .defaults
            }
            unreadable = false
            switch state {
            case let .readable(prefs):
                return prefs
            case .damaged:
                _ = moveAside()
                return .defaults
            case .missing, .unreadable:
                return .defaults
            }
        }
    }

    public func save(_ preferences: AppPreferences) async {
        lock.withLock { unreadable in
            switch readFile() {
            case .unreadable:
                unreadable = true
                return
            case .damaged:
                guard !unreadable, moveAside() else { return }
            case .missing, .readable:
                guard !unreadable else { return }
            }
            write(preferences)
        }
    }

    public func update(_ change: @Sendable (inout AppPreferences) -> Void) async -> AppPreferences {
        lock.withLock { unreadable in
            var base = AppPreferences.defaults
            var writable = !unreadable
            switch readFile() {
            case .missing:
                break
            case let .readable(prefs):
                base = prefs
            case .damaged:
                writable = writable && moveAside()
            case .unreadable:
                unreadable = true
                writable = false
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
        /// The file exists but its bytes could not be read; says nothing about its contents.
        case unreadable
    }

    private func readFile() -> FileState {
        guard FileManager.default.fileExists(atPath: file.path) else { return .missing }
        guard let data = try? Data(contentsOf: file) else { return .unreadable }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        guard var prefs = try? decoder.decode(AppPreferences.self, from: data) else { return .damaged }
        prefs.schedule = prefs.schedule.clamped()
        return .readable(prefs)
    }

    /// Returns false when the damaged file is still in place. Nothing is permanently deleted: a new copy gets a name
    /// not yet taken (`moveItem` refuses an existing destination), and once `maxDamagedCopies` exist the oldest copy
    /// is first moved to the Trash; if that fails, the damaged file stays where it is.
    private func moveAside() -> Bool {
        guard !failMovingAside else { return false }
        let manager = FileManager.default
        let copies = ((try? manager.contentsOfDirectory(atPath: directory.path)) ?? [])
            .compactMap(DamagedCopy.init(name:))
            .sorted()
        let stamp = Int(now().timeIntervalSince1970)
        let counter = (copies.filter { $0.stamp == stamp }.map(\.counter).max() ?? 0) + 1
        let fresh = directory.appendingPathComponent(DamagedCopy.name(stamp: stamp, counter: counter))
        if copies.count >= Self.maxDamagedCopies, let oldest = copies.first {
            guard (try? trash(directory.appendingPathComponent(oldest.name))) != nil else { return false }
        }
        return (try? manager.moveItem(at: file, to: fresh)) != nil
    }

    /// A copy named `preferences.json.damaged-<stamp>` (counter 1) or `preferences.json.damaged-<stamp>-<counter>`.
    private struct DamagedCopy: Comparable {
        let name: String
        let stamp: Int
        let counter: Int

        /// Nil for a name that is not a damaged copy; a copy with an unexpected suffix sorts as the oldest.
        init?(name: String) {
            guard name.hasPrefix(PreferencesStore.damagedPrefix) else { return nil }
            self.name = name
            let parts = name.dropFirst(PreferencesStore.damagedPrefix.count).split(separator: "-")
            let first = parts.first.flatMap { Int($0) }
            let second = parts.count == 2 ? Int(parts[1]) : 1
            if parts.count <= 2, let first, let second {
                stamp = first
                counter = second
            } else {
                stamp = Int.min
                counter = 0
            }
        }

        static func name(stamp: Int, counter: Int) -> String {
            counter == 1
                ? "\(PreferencesStore.damagedPrefix)\(stamp)"
                : "\(PreferencesStore.damagedPrefix)\(stamp)-\(counter)"
        }

        static func < (lhs: Self, rhs: Self) -> Bool {
            (lhs.stamp, lhs.counter, lhs.name) < (rhs.stamp, rhs.counter, rhs.name)
        }
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
