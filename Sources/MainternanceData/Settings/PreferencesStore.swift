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
/// fresh name, so saving keeps working. Only names the store itself makes count as copies: any other file (say
/// `preferences.json.damaged-backup`) is never counted, rotated or moved to the Trash. If the oldest copy's path is
/// protected (`ProtectedPaths`), or it cannot be moved to the Trash, or moving aside fails, the damaged file stays
/// where it is and saving is skipped.
/// A file that exists but cannot be READ (no permission, a directory in its place, an I/O error) is not damaged: it is
/// left alone and loading gives the defaults. `update` reads the file again every time and applies its change to
/// what it holds, so it saves again as soon as the read works; `save` (a whole-file replace) waits for a `load` or
/// `update` that reads the file, so defaults shown after a passing read error are never written over the owner's
/// choices. Every write says whether it reached the disk.
/// A schedule out of range is clamped on load; a missing field takes its default (so a field added later never resets
/// the owner's other choices).
/// Reads and writes happen inside one lock, so concurrent saves and updates are serialised and the file is always
/// whole; `update` reads, changes and writes inside that one lock.
public final class PreferencesStore: PreferencesStoring, Sendable {
    /// How many damaged copies may sit beside the file. Beyond that the oldest goes to the Trash.
    static let maxDamagedCopies = 5

    private let directory: URL
    private let file: URL
    private let now: @Sendable () -> Date
    private let trash: @Sendable (URL) throws -> Void
    private let isProtected: @Sendable (String) -> Bool
    /// True from a read that failed until a load or update reads the file (or finds it missing or damaged): `save`
    /// is skipped meanwhile.
    private let lock = Mutex(false)
    private let moveAsideFails = Mutex(false)
    private let writeFailure = Mutex(false)
    private let afterReadHook = Mutex<(@Sendable () -> Void)?>(nil)

    /// Test seam: makes moving a damaged file aside fail.
    var failMovingAside: Bool {
        get { moveAsideFails.withLock { $0 } }
        set { moveAsideFails.withLock { $0 = newValue } }
    }

    /// Test seam: makes every write fail, as a full disk or a folder that cannot be written would.
    var failWriting: Bool {
        get { writeFailure.withLock { $0 } }
        set { writeFailure.withLock { $0 = newValue } }
    }

    /// Test seam: runs inside the lock, after `update` read the file and before it writes.
    var afterRead: (@Sendable () -> Void)? {
        get { afterReadHook.withLock { $0 } }
        set { afterReadHook.withLock { $0 = newValue } }
    }

    /// `now` names damaged copies and judges a recorded run that lies too far ahead. `trash` moves the oldest damaged
    /// copy to the Trash (tests pass a fake so they never touch the real Trash). `isProtected` is asked about the
    /// copy's whole path first; a protected path is never moved.
    public init(
        directory: URL,
        now: @escaping @Sendable () -> Date = Date.init,
        trash: @escaping @Sendable (URL) throws -> Void = SystemTrash.move,
        isProtected: @escaping @Sendable (String) -> Bool = { ProtectedPaths.isProtected($0) }
    ) {
        self.directory = directory
        file = directory.appendingPathComponent("preferences.json")
        self.now = now
        self.trash = trash
        self.isProtected = isProtected
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

    /// A whole-file replace: after a passing read error it stays skipped until a `load` or `update` reads the file
    /// again (the values given may be defaults shown because of that error).
    @discardableResult
    public func save(_ preferences: AppPreferences) async -> Bool {
        lock.withLock { unreadable in
            switch readFile() {
            case .unreadable:
                unreadable = true
                return false
            case .damaged:
                guard !unreadable, moveAside() else { return false }
            case .missing, .readable:
                guard !unreadable else { return false }
            }
            return write(preferences)
        }
    }

    /// Reads the file again each time: a read that works clears an earlier read error, so one passing error never
    /// stops saving for the rest of the session (the change is applied to what the file holds, never to defaults
    /// shown because of that error).
    @discardableResult
    public func update(_ change: @Sendable (inout AppPreferences) -> Void) async -> PreferencesUpdate {
        lock.withLock { unreadable in
            var base = AppPreferences.defaults
            var writable = true
            switch readFile() {
            case .missing:
                unreadable = false
            case let .readable(prefs):
                unreadable = false
                base = prefs
            case .damaged:
                unreadable = false
                writable = moveAside()
            case .unreadable:
                unreadable = true
                writable = false
            }
            afterRead?()
            let next = base.updated(now: now(), change)
            let saved = writable && write(next)
            return PreferencesUpdate(preferences: next, saved: saved)
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

    /// Returns false when the damaged file is still in place (see `DamagedFileMover`).
    private func moveAside() -> Bool {
        guard !failMovingAside else { return false }
        return DamagedFileMover(
            directory: directory, fileName: "preferences.json", maxCopies: Self.maxDamagedCopies,
            now: now, trash: trash, isProtected: isProtected
        ).moveAside()
    }

    private func write(_ preferences: AppPreferences) -> Bool {
        guard !failWriting else { return false }
        return PrivateJSONFile.write(preferences, to: file)
    }
}
