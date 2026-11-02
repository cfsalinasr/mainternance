import Darwin
import Foundation

/// Pure path checks used to distrust scanner output: a file name may contain newlines and so forge whole lines.
public enum ScanPathRules {
    /// An absolute path with no `.` / `..` / empty components and no NUL.
    public static func isPlainAbsolute(_ path: String) -> Bool {
        guard path.hasPrefix("/"), !path.contains("\0") else { return false }
        let components = path.split(separator: "/", omittingEmptySubsequences: false).dropFirst()
        return !components.contains { $0 == "." || $0 == ".." } && !path.contains("//") && path != "/"
    }

    /// `path` is `directory` itself or lies below it. Compares whole path components (`/Users/a` does not contain
    /// `/Users/ab`). A `/` directory contains nothing here: scans never use it.
    public static func isInside(_ path: String, directory: String) -> Bool {
        guard directory != "/", !directory.isEmpty else { return false }
        return path == directory || path.hasPrefix(directory + "/")
    }

    /// True when the path is a regular file itself (lstat: a symlink or a directory is not).
    public static func isRegularFile(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFREG
    }

    /// True when the path exists. lstat semantics: a symlink counts as existing, even a dangling one.
    @Sendable
    public static func lstatExists(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0
    }
}
