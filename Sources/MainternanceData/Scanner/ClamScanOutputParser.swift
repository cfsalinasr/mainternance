import Foundation

/// What one line of `clamscan -v --no-summary` output means.
public enum ClamLine: Equatable, Sendable {
    /// `<path>: OK`
    case scanned(path: String)
    /// `<path>: <Signature> FOUND`
    case found(path: String, signature: String)
    /// `<path>: <message> ERROR`; `isPermission` for permission-denied / not-permitted / cannot-open messages.
    case unreadable(path: String, isPermission: Bool)
    /// Anything else: informational lines (`Empty file`, `Excluded`), warnings, noise.
    case ignored
}

/// Parses single `clamscan` output lines. Pure.
///
/// The verdict is the END of the line (`: OK`, ` FOUND`, ` ERROR`), and the path is whatever precedes the last
/// `": "` before it, so paths containing `: `, `FOUND`, `OK` or `ERROR` still parse correctly. Signature names and
/// error messages never contain `": "` themselves.
public enum ClamScanOutputParser {
    private static let separator = ": "
    private static let permissionMarkers = [
        "permission denied", "operation not permitted", "can't open file or directory"
    ]

    public static func parse(_ line: String) -> ClamLine {
        if line.hasSuffix(": OK") {
            let path = String(line.dropLast(4))
            return path.isEmpty ? .ignored : .scanned(path: path)
        }
        if line.hasSuffix(" FOUND") {
            return split(String(line.dropLast(6))).map { .found(path: $0.path, signature: $0.rest) } ?? .ignored
        }
        if line.hasSuffix(" ERROR") {
            guard let parts = split(String(line.dropLast(6))) else { return .ignored }
            let message = parts.rest.lowercased()
            return .unreadable(path: parts.path, isPermission: permissionMarkers.contains { message.contains($0) })
        }
        return .ignored
    }

    /// Splits at the LAST `": "`; both halves must be non-empty.
    private static func split(_ text: String) -> (path: String, rest: String)? {
        guard let range = text.range(of: separator, options: .backwards) else { return nil }
        let path = String(text[..<range.lowerBound])
        let rest = String(text[range.upperBound...])
        return path.isEmpty || rest.isEmpty ? nil : (path, rest)
    }
}
