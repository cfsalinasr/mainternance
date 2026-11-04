import Foundation

/// What one line of `clamscan -v --no-summary` output means.
public enum ClamLine: Equatable, Sendable {
    /// `<path>: OK`
    case scanned(path: String)
    /// `<path>: <Signature> FOUND`
    case found(path: String, signature: String)
    /// A file clamscan could not read; `isPermission` for permission-type reasons.
    case unreadable(path: String, isPermission: Bool)
    /// `<dir>: Can't open directory.`: a folder clamscan could not enter, so nothing inside it was scanned.
    case unreadableFolder(path: String)
    /// `<path>: Heuristics.Limits.Exceeded[.<limit>] FOUND` (printed with `--alert-exceeds-max=yes`): the file is
    /// over a size or scan limit and was skipped or only partly read. Never a finding, never clean.
    case tooLarge(path: String)
    /// Anything else: `Scanning <path>` progress lines, informational lines (`Empty file`, `Excluded`), noise.
    case ignored
}

/// Parses single `clamscan` output lines. Pure.
///
/// Forms, as printed by upstream ClamAV (`clamscan/manager.c`, `common/output.c`; see the Task 5 fix report):
/// - stdout `<path>: OK`, `<path>: <Signature> FOUND`, `<path>: <cl_strerror> ERROR`
/// - stdout `<path>: Access denied` (a file the user cannot read), `<dir>: Can't open directory.`
/// - stderr `WARNING: Can't open file <path>: <strerror>` (open failed, e.g. `Permission denied`)
/// - stdout `<path>: Heuristics.Limits.Exceeded.<Limit> FOUND` (with `--alert-exceeds-max=yes`): over a limit.
/// - stdout `Scanning <path>` (`-v` progress) and informational `<path>: Empty file` / `Excluded` /
///   `Symbolic link`: ignored.
///
/// Every per-file form except FOUND and the WARNING one must start with `/` (roots are absolute); `Scanning ...`
/// lines are always ignored, so they can never be mistaken for verdicts. The verdict is the END of the line and the
/// path is whatever precedes the last
/// `": "` before it, so paths containing `: `, `FOUND`, `OK` or `ERROR` still parse. Signature names never contain
/// `": "`. An `ERROR` message that itself contains `": "` is attributed to a shortened path (still one unreadable
/// entry for the right file, only the path text is cut); the caller validates every path against the scan roots.
public enum ClamScanOutputParser {
    private static let separator = ": "
    private static let cantOpenFile = "WARNING: Can't open file "
    /// The name family clamscan gives a file it skipped for its limits (MaxFileSize, MaxScanSize, MaxFiles, ...).
    private static let limitsExceeded = "Heuristics.Limits.Exceeded"
    private static let permissionMarkers = [
        "permission denied", "operation not permitted", "access denied", "can't open file or directory"
    ]

    public static func parse(_ line: String) -> ClamLine {
        if line.hasPrefix(cantOpenFile) {
            return parseCantOpen(String(line.dropFirst(cantOpenFile.count)))
        }
        // `Scanning <path>` is -v progress, never a verdict, whatever the path ends with.
        if line.hasPrefix("Scanning ") {
            return .ignored
        }
        // A FOUND line is parsed even when its path is not absolute: the caller must see it to account for a
        // detection whose line was mangled by a file name (a dropped detection is never silent).
        if line.hasSuffix(" FOUND") {
            return parseFound(String(line.dropLast(6)))
        }
        guard line.hasPrefix("/") else { return .ignored }
        if line.hasSuffix(": OK") {
            return .scanned(path: String(line.dropLast(4)))
        }
        if line.hasSuffix(" ERROR") {
            guard let parts = split(String(line.dropLast(6))) else { return .ignored }
            return .unreadable(path: parts.path, isPermission: isPermission(parts.rest))
        }
        if line.hasSuffix(": Access denied") {
            return .unreadable(path: String(line.dropLast(15)), isPermission: true)
        }
        if line.hasSuffix(": Can't open directory.") {
            // The reason is not printed. opendir() on a listed directory fails for permissions in practice
            // (macOS privacy protection), so callers treat it as a permission problem.
            return .unreadableFolder(path: String(line.dropLast(23)))
        }
        return .ignored
    }

    /// A limits alert is a file skipped for being too large, never a detection.
    private static func parseFound(_ rest: String) -> ClamLine {
        guard let parts = split(rest) else { return .ignored }
        if isLimitsExceeded(parts.rest) {
            return .tooLarge(path: parts.path)
        }
        return .found(path: parts.path, signature: parts.rest)
    }

    private static func parseCantOpen(_ rest: String) -> ClamLine {
        guard let parts = split(rest) else { return .ignored }
        return .unreadable(path: parts.path, isPermission: isPermission(parts.rest))
    }

    private static func isLimitsExceeded(_ signature: String) -> Bool {
        signature == limitsExceeded || signature.hasPrefix(limitsExceeded + ".")
    }

    private static func isPermission(_ message: String) -> Bool {
        let lowered = message.lowercased()
        return permissionMarkers.contains { lowered.contains($0) }
    }

    /// Splits at the LAST `": "`; both halves must be non-empty.
    private static func split(_ text: String) -> (path: String, rest: String)? {
        guard let range = text.range(of: separator, options: .backwards) else { return nil }
        let path = String(text[..<range.lowerBound])
        let rest = String(text[range.upperBound...])
        return path.isEmpty || rest.isEmpty ? nil : (path, rest)
    }
}
