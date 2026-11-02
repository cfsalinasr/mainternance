import Foundation
import MainternanceDomain
import Synchronization

/// Remembers which startup items the owner has seen, as `startup-review.json` (mode `0o600`, written atomically)
/// in `directory`: the items' `reviewKey`s.
///
/// The same rules as `PreferencesStore`: a file that cannot be decoded is never overwritten and never deleted; it
/// is moved aside by `DamagedFileMover` (bounded copies, the oldest to the Trash, the protected-paths guard first,
/// strict names) before anything new is written. A file that exists but cannot be READ is left alone and nothing is
/// written. Either way, while the baseline cannot be read nothing counts as new (`unreadable`): a lost baseline must
/// not make every item look new. Every read and write happens inside one lock.
public final class StartupReviewStore: StartupReviewing, Sendable {
    /// How many damaged copies may sit beside the file. Beyond that the oldest goes to the Trash.
    static let maxDamagedCopies = 5
    static let fileName = "startup-review.json"

    enum Baseline: Equatable {
        /// No baseline yet (or one was just created by this call).
        case missing
        case reviewed(Set<String>)
        /// The file could not be read, or it is damaged and could not be moved aside (or was not asked to be).
        case unreadable
    }

    private let file: URL
    private let mover: DamagedFileMover
    private let now: @Sendable () -> Date
    private let lock = Mutex(())

    public init(
        directory: URL,
        now: @escaping @Sendable () -> Date = Date.init,
        trash: @escaping @Sendable (URL) throws -> Void = PreferencesStore.moveToTrash,
        isProtected: @escaping @Sendable (String) -> Bool = { ProtectedPaths.isProtected($0) }
    ) {
        file = directory.appendingPathComponent(Self.fileName)
        self.now = now
        mover = DamagedFileMover(
            directory: directory, fileName: Self.fileName, maxCopies: Self.maxDamagedCopies,
            now: now, trash: trash, isProtected: isProtected
        )
    }

    /// The saved baseline. With `keys`, a missing baseline is created from them (the first listing); a damaged file
    /// is moved aside first and then replaced the same way. Without `keys` (Home's counter) nothing is ever moved or
    /// written, and a damaged file reads as `unreadable`.
    func baseline(establishing keys: Set<String>?) -> Baseline {
        lock.withLock { _ in
            switch readFile() {
            case let .readable(saved):
                return .reviewed(saved)
            case .unreadable:
                return .unreadable
            case .missing:
                if let keys {
                    write(keys)
                }
                return .missing
            case .damaged:
                guard let keys, mover.moveAside() else { return .unreadable }
                write(keys)
                return .missing
            }
        }
    }

    public func markReviewed(_ labels: [String]) async {
        lock.withLock { _ in
            switch readFile() {
            case .unreadable:
                return
            case .damaged:
                guard mover.moveAside() else { return }
            case .missing, .readable:
                break
            }
            write(Set(labels))
        }
    }

    private struct ReviewFile: Codable {
        var reviewed: [String]
        var reviewedAt: Date?
    }

    private enum FileState {
        case missing
        case readable(Set<String>)
        case damaged
        /// The file exists but its bytes could not be read; says nothing about its contents.
        case unreadable
    }

    private func readFile() -> FileState {
        guard FileManager.default.fileExists(atPath: file.path) else { return .missing }
        guard let data = try? Data(contentsOf: file) else { return .unreadable }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        guard let saved = try? decoder.decode(ReviewFile.self, from: data) else { return .damaged }
        return .readable(Set(saved.reviewed))
    }

    private func write(_ keys: Set<String>) {
        PrivateJSONFile.write(ReviewFile(reviewed: keys.sorted(), reviewedAt: now()), to: file)
    }
}
