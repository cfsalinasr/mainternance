import Foundation

/// Which files a scan of one scope looks at, as the engine applies it: the folders it walks and the folders it
/// skips. Used to decide whether a finished scan can say anything about an older finding: only a path that the scan
/// covered can be dropped when the scan no longer detects it.
public struct ScanCoverage: Sendable, Equatable {
    /// Absolute, standardized folders (or files) the scan walks.
    public let roots: [String]
    /// Absolute, standardized folders the scan never enters (quarantine, ClamAV data, cloud folders on full scans).
    public let excluded: [String]

    public init(roots: [String], excluded: [String]) {
        self.roots = roots
        self.excluded = excluded
    }

    /// True when `path` lies under a root and outside every excluded folder. Whole path components are compared,
    /// so `/Users/a/Docs2/x` is not under `/Users/a/Docs`.
    public func covers(_ path: String) -> Bool {
        guard let candidate = Self.standardized(path),
              roots.contains(where: { Self.contains(tree: $0, candidate) }) else { return false }
        return !excluded.contains { Self.contains(tree: $0, candidate) }
    }

    private static func standardized(_ path: String) -> String? {
        guard path.hasPrefix("/") else { return nil }
        return URL(fileURLWithPath: path).standardizedFileURL.path
    }

    private static func contains(tree: String, _ candidate: String) -> Bool {
        guard let root = standardized(tree) else { return false }
        return candidate == root || candidate.hasPrefix(root == "/" ? "/" : root + "/")
    }
}

/// The one place that knows how the engine words "N detections could not be attributed" inside a failed scan's
/// message, so the sentence is written and read with the same code.
public enum ScanFailureNote {
    /// The clause appended to a failure message. `detection(s)` is the engine's wording, not shown to the user.
    public static func unattributedClause(_ count: Int) -> String {
        " and \(count) \(marker)"
    }

    private static let marker = "detection(s) could not be attributed to a file"

    /// The count in the FIRST such clause of `message`, 0 when there is none. Only the first one counts: text after
    /// it can come from file names.
    public static func unattributedCount(in message: String) -> Int {
        let pattern = " and ([0-9]{1,9}) " + NSRegularExpression.escapedPattern(for: marker)
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(in: message, range: NSRange(message.startIndex..., in: message)),
              let range = Range(match.range(at: 1), in: message)
        else {
            return 0
        }
        return Int(message[range]) ?? 0
    }
}
