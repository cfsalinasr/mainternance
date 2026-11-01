import Foundation

/// Which files a scan of one scope looks at, as the engine applies it: the folders it walks and the folders it
/// skips. Used to decide whether a finished scan can say anything about an older finding: only a path that the scan
/// covered can be dropped when the scan no longer detects it.
public struct ScanCoverage: Sendable {
    /// Absolute, standardized folders (or files) the scan walks.
    public let roots: [String]
    /// Absolute, standardized folders the scan never enters (quarantine, ClamAV data, cloud folders on full scans).
    public let excluded: [String]

    /// Maps a standardized path to the canonical path the scan walks (symlinks resolved), or nil when that cannot be
    /// told. Nil means NOT covered. Without one, paths are compared as text.
    private let resolve: (@Sendable (String) -> String?)?

    public init(roots: [String], excluded: [String], resolve: (@Sendable (String) -> String?)? = nil) {
        self.roots = roots
        self.excluded = excluded
        self.resolve = resolve
    }

    /// True when `path` lies under a root and outside every excluded folder. Whole path components are compared,
    /// so `/Users/a/Docs2/x` is not under `/Users/a/Docs`.
    public func covers(_ path: String) -> Bool {
        guard let standardized = Self.standardized(path) else { return false }
        var candidate = standardized
        if let resolve {
            guard let real = resolve(standardized) else { return false }
            candidate = real
        }
        guard roots.contains(where: { Self.contains(tree: $0, candidate) }) else { return false }
        return !excluded.contains { Self.contains(tree: $0, candidate) }
    }

    /// Absolute path without `.`, `..` and empty components, worked out on the text alone. (Foundation's
    /// `standardizedFileURL` also rewrites `/private/var` to `/var`, which would break the comparison of real paths.)
    private static func standardized(_ path: String) -> String? {
        guard path.hasPrefix("/") else { return nil }
        var parts: [Substring] = []
        for part in path.split(separator: "/", omittingEmptySubsequences: true) {
            if part == "." {
                continue
            }
            if part == ".." {
                _ = parts.popLast()
            } else {
                parts.append(part)
            }
        }
        return "/" + parts.joined(separator: "/")
    }

    private static func contains(tree: String, _ candidate: String) -> Bool {
        guard let root = standardized(tree) else { return false }
        return candidate == root || candidate.hasPrefix(root == "/" ? "/" : root + "/")
    }
}

/// The wording the engine appends to a failed scan's message. It is for DISPLAY only: the count is carried by
/// `ScanEvent.unattributed` and is never parsed back out of a message.
public enum ScanFailureNote {
    /// The clause appended to a failure message.
    public static func unattributedClause(_ count: Int) -> String {
        " and \(count) \(marker)"
    }

    private static let marker = "detection(s) could not be attributed to a file"
}
