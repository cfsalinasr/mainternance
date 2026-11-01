import Darwin
import Foundation

/// Real-path helpers for `ScanCoverage`. A scan only covers what it really walks, so both sides of a comparison are
/// resolved through symbolic links, and when that cannot be done the answer is "not covered".
enum CoveragePaths {
    /// The canonical path (every link resolved) of an existing item; nil when it does not exist.
    static func realPath(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// True when the last component of `path` is itself a symbolic link (not followed).
    static func isSymbolicLink(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFLNK
    }

    /// Resolves the existing parent folder of `path` and keeps the last component as it is, so a finding that is
    /// gone can still be placed. Nil when the parent does not exist or the path has no usable shape.
    @Sendable
    static func resolve(_ path: String) -> String? {
        guard path.hasPrefix("/") else { return nil }
        let url = URL(fileURLWithPath: path)
        let name = url.lastPathComponent
        guard !name.isEmpty, name != "/", let parent = realPath(url.deletingLastPathComponent().path) else {
            return nil
        }
        return parent == "/" ? "/" + name : parent + "/" + name
    }
}
