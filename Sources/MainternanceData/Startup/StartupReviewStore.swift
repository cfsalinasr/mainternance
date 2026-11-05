import Foundation
import MainternanceDomain
import Synchronization

/// Remembers which startup items the owner has seen, as `startup-review.json` (mode `0o600`, written atomically)
/// in `directory`: the items' `reviewKey`s, also grouped by kind so that what was known for a launchd folder that
/// could not be opened at the next review is kept rather than dropped.
///
/// The same rules as `PreferencesStore`: a file that cannot be decoded (or is larger than `maxBytes`) is never
/// overwritten and never deleted; it is moved aside by `DamagedFileMover` (bounded copies, the oldest to the Trash,
/// the protected-paths guard first, strict names) before anything new is written. A file that exists but cannot be
/// READ (no permission, not a regular file) is left alone and nothing is written. Either way, while the baseline
/// cannot be read nothing counts as new (`unreadable`): a lost baseline must not make every item look new. The file
/// is read with `BoundedFileRead` (non-blocking, regular files only). Every read and write happens inside one lock.
public final class StartupReviewStore: Sendable {
    /// How many damaged copies may sit beside the file. Beyond that the oldest goes to the Trash.
    static let maxDamagedCopies = 5
    static let fileName = "startup-review.json"
    /// Larger files are not ours: they are treated as damaged.
    static let maxBytes = 1 << 20

    enum Baseline: Equatable {
        /// No baseline yet (or one was just created by this call); `saved` says whether that creation was written.
        case missing(saved: Bool)
        case reviewed(Set<String>)
        /// The file could not be read, or it is damaged and could not be moved aside (or was not asked to be).
        case unreadable
    }

    private let file: URL
    private let directory: URL
    private let mover: DamagedFileMover
    private let now: @Sendable () -> Date
    private let lock = Mutex(())

    public init(
        directory: URL,
        now: @escaping @Sendable () -> Date = Date.init,
        trash: @escaping @Sendable (URL) throws -> Void = SystemTrash.move,
        isProtected: @escaping @Sendable (String) -> Bool = { ProtectedPaths.isProtected($0) }
    ) {
        self.directory = directory
        file = directory.appendingPathComponent(Self.fileName)
        self.now = now
        mover = DamagedFileMover(
            directory: directory, fileName: Self.fileName, maxCopies: Self.maxDamagedCopies,
            now: now, trash: trash, isProtected: isProtected
        )
    }

    /// The saved baseline. With `items`, a missing baseline is created from them (the first listing); a damaged
    /// file is moved aside first and then replaced the same way. Without `items` (Home's counter) nothing is ever
    /// moved or written, and a damaged file reads as `unreadable`.
    func baseline(establishing items: [StartupItem]?) -> Baseline {
        lock.withLock { _ in
            switch readFile() {
            case let .readable(saved):
                return .reviewed(saved.all)
            case .unreadable:
                return .unreadable
            case .missing:
                guard let items else { return .missing(saved: false) }
                return .missing(saved: write(Saved(items: items)))
            case .damaged:
                guard let items, mover.moveAside() else { return .unreadable }
                return .missing(saved: write(Saved(items: items)))
            }
        }
    }

    /// Makes `items` the baseline; for each kind in `keeping` (its folder could not be opened) what was known for it
    /// before stays. False when nothing could be saved: the file cannot be read, a damaged one could not be moved
    /// aside, or the write failed.
    func markReviewed(_ items: [StartupItem], keeping: Set<StartupKind>) -> Bool {
        lock.withLock { _ in
            var next = Saved(items: items)
            switch readFile() {
            case .unreadable:
                return false
            case .damaged:
                guard mover.moveAside() else { return false }
            case .missing:
                break
            case let .readable(previous):
                for kind in keeping {
                    next.byKind[kind, default: []].formUnion(previous.known(for: kind))
                }
            }
            return write(next)
        }
    }

    /// Saves the current keys of `items` (each reviewed under a key from before programs were part of the review)
    /// in place of their old keys. False when nothing could be saved; the old keys then stay and the upgrade is
    /// tried again at the next listing.
    func upgrade(_ items: [StartupItem]) -> Bool {
        lock.withLock { _ in
            guard case var .readable(saved) = readFile() else { return false }
            for item in items {
                let old = Set(StartupReviewBaseline.legacyKeys(of: item))
                saved.byKind[item.kind, default: []].subtract(old)
                saved.byKind[item.kind, default: []].insert(item.reviewKey)
                saved.legacy.subtract(old)
            }
            return write(saved)
        }
    }

    /// Whether a write could succeed: the folder (or, while it does not exist, the nearest folder above it) can be
    /// written by this user.
    func canWrite() -> Bool {
        var folder = directory
        let manager = FileManager.default
        while !manager.fileExists(atPath: folder.path), folder.pathComponents.count > 1 {
            folder = folder.deletingLastPathComponent()
        }
        return access(folder.path, W_OK | X_OK) == 0
    }

    /// The keys, by kind. A file from before kinds were saved has only `all`.
    private struct Saved {
        var byKind: [StartupKind: Set<String>]
        var legacy: Set<String> = []

        init(items: [StartupItem]) {
            byKind = Dictionary(grouping: items, by: \.kind).mapValues { Set($0.map(\.reviewKey)) }
        }

        init(byKind: [StartupKind: Set<String>], legacy: Set<String>) {
            self.byKind = byKind
            self.legacy = legacy
        }

        var all: Set<String> {
            byKind.values.reduce(legacy) { $0.union($1) }
        }

        /// Without kinds saved, every old key is kept (the safe side: nothing silently dropped).
        func known(for kind: StartupKind) -> Set<String> {
            (byKind[kind] ?? []).union(legacy)
        }
    }

    private struct ReviewFile: Codable {
        var reviewed: [String]
        var reviewedAt: Date?
        /// `StartupKind` name -> keys; absent in files written before kinds were saved.
        var byKind: [String: [String]]?
    }

    private static func name(_ kind: StartupKind) -> String {
        switch kind {
        case .userAgent: "userAgent"
        case .systemAgent: "systemAgent"
        case .systemDaemon: "systemDaemon"
        }
    }

    private enum FileState {
        case missing
        case readable(Saved)
        case damaged
        /// The file exists but its bytes could not be read; says nothing about its contents.
        case unreadable
    }

    private func readFile() -> FileState {
        let data: Data
        switch BoundedFileRead.data(at: file.path, maxBytes: Self.maxBytes) {
        case let .success(bytes): data = bytes
        case .failure(.missing): return .missing
        case .failure(.tooLarge): return .damaged
        case .failure(.cannotOpen), .failure(.notRegularFile): return .unreadable
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        guard let saved = try? decoder.decode(ReviewFile.self, from: data) else { return .damaged }
        guard let byName = saved.byKind else {
            return .readable(Saved(byKind: [:], legacy: Set(saved.reviewed)))
        }
        var byKind: [StartupKind: Set<String>] = [:]
        for kind in StartupKind.allCases {
            byKind[kind] = byName[Self.name(kind)].map(Set.init)
        }
        // Keys under no known kind are still remembered, and kept for every kind.
        let grouped = byKind.values.reduce(Set<String>()) { $0.union($1) }
        return .readable(Saved(byKind: byKind, legacy: Set(saved.reviewed).subtracting(grouped)))
    }

    private func write(_ saved: Saved) -> Bool {
        var byName: [String: [String]] = [:]
        for (kind, keys) in saved.byKind {
            byName[Self.name(kind)] = keys.sorted()
        }
        let value = ReviewFile(reviewed: saved.all.sorted(), reviewedAt: now(), byKind: byName)
        return PrivateJSONFile.write(value, to: file)
    }
}
