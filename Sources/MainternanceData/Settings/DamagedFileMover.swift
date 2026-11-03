import Foundation

/// Moves a damaged file of the app's own (`directory/fileName`) aside, never deleting anything.
///
/// The copy is named `<fileName>.damaged-<unix seconds>` (with `-2`, `-3`, ... when that name is taken). At most
/// `maxCopies` such copies are kept beside the file: once that many exist, the oldest copy is moved to the Trash
/// (never permanently deleted) and the newest damaged file takes a fresh name. Only names this helper itself makes
/// count as copies: any other file (say `<fileName>.damaged-backup`) is never counted, rotated or moved to the
/// Trash. If the oldest copy's path is protected (`isProtected`, asked about the whole path first), or it cannot be
/// moved to the Trash, or moving aside fails, the damaged file stays where it is and `moveAside` returns false.
struct DamagedFileMover: Sendable {
    let directory: URL
    let fileName: String
    let maxCopies: Int
    let now: @Sendable () -> Date
    let trash: @Sendable (URL) throws -> Void
    let isProtected: @Sendable (String) -> Bool

    private var prefix: String {
        "\(fileName).damaged-"
    }

    /// Returns false when the damaged file is still in place. A new copy gets a name not yet taken (`moveItem`
    /// refuses an existing destination).
    func moveAside() -> Bool {
        let manager = FileManager.default
        let copies = ((try? manager.contentsOfDirectory(atPath: directory.path)) ?? [])
            .compactMap { DamagedCopy(name: $0, prefix: prefix) }
            .sorted()
        let stamp = Int(now().timeIntervalSince1970)
        let counter = (copies.filter { $0.stamp == stamp }.map(\.counter).max() ?? 0) + 1
        let fresh = directory.appendingPathComponent(DamagedCopy.name(prefix: prefix, stamp: stamp, counter: counter))
        if copies.count >= maxCopies, let oldest = copies.first {
            let target = directory.appendingPathComponent(oldest.name)
            guard !isProtected(target.path), (try? trash(target)) != nil else { return false }
        }
        let file = directory.appendingPathComponent(fileName)
        return (try? manager.moveItem(at: file, to: fresh)) != nil
    }

    /// A copy named `<prefix><stamp>` (counter 1) or `<prefix><stamp>-<counter>`.
    private struct DamagedCopy: Comparable {
        let name: String
        let stamp: Int
        let counter: Int

        /// Nil for any name the mover would not make: exactly `<prefix><digits>` or `<prefix><digits>-<digits>`
        /// with a counter of 2 or more, ASCII digits only and no leading zeros.
        init?(name: String, prefix: String) {
            guard name.hasPrefix(prefix) else { return nil }
            let parts = name.dropFirst(prefix.count).split(separator: "-", omittingEmptySubsequences: false)
            guard parts.count == 1 || parts.count == 2, let first = Self.number(parts[0]) else { return nil }
            let second = parts.count == 2 ? Self.number(parts[1]) : 1
            guard let second, parts.count == 1 || second >= 2 else { return nil }
            self.name = name
            stamp = first
            counter = second
        }

        /// The value of a run of ASCII digits with no leading zero (as the mover writes it); nil for anything else.
        private static func number(_ text: Substring) -> Int? {
            guard !text.isEmpty, text.allSatisfy({ ("0" ... "9").contains($0) }),
                  text == "0" || text.first != "0" else { return nil }
            return Int(text)
        }

        static func name(prefix: String, stamp: Int, counter: Int) -> String {
            counter == 1 ? "\(prefix)\(stamp)" : "\(prefix)\(stamp)-\(counter)"
        }

        static func < (lhs: Self, rhs: Self) -> Bool {
            (lhs.stamp, lhs.counter, lhs.name) < (rhs.stamp, rhs.counter, rhs.name)
        }
    }
}
