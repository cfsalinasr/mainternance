import Foundation

/// Places the quarantine must never move, however the path is spelled.
///
/// Pure path math (it only reads symlinks to resolve them): `..`, repeated slashes, symlinked prefixes
/// (`/etc` -> `/private/etc`) and letter case (the volume is case-insensitive) cannot dodge the check.
/// A path that is not absolute is refused, because its meaning depends on the working directory.
public enum ProtectedPaths {
    /// Folders protected together with everything below them.
    private static let protectedTrees = [
        "/System", "/usr", "/bin", "/sbin", "/Library/Apple", "/private/var/db", "/private/etc"
    ]

    /// True when `path` is protected: a system tree, the root, the home folder itself, or the running app bundle.
    public static func isProtected(_ path: String) -> Bool {
        isProtected(path, including: [])
    }

    /// Like `isProtected(_:)`, with extra folders (for example the quarantine folder) protected together with
    /// everything below them.
    public static func isProtected(_ path: String, including extraTrees: [URL]) -> Bool {
        guard let candidate = normalize(path) else { return true }
        if candidate == "/" {
            return true
        }
        let trees = protectedTrees.compactMap(normalize)
            + [Bundle.main.bundlePath].compactMap(normalize)
            + extraTrees.compactMap { normalize($0.path) }
        if trees.contains(where: { contains(tree: $0, candidate) }) {
            return true
        }
        let home = normalize(FileManager.default.homeDirectoryForCurrentUser.path)
        return candidate == home
    }

    private static func contains(tree: String, _ candidate: String) -> Bool {
        candidate == tree || candidate.hasPrefix(tree + "/")
    }

    /// Absolute, standardized, symlink-resolved and lowercased; nil for a path that is empty or relative.
    /// Symlinks are resolved with `realpath` on the deepest part that exists (Foundation's own resolution drops
    /// `/private` only for some paths, which would make the same place compare differently).
    static func normalize(_ path: String) -> String? {
        guard path.hasPrefix("/") else { return nil }
        var existing = URL(fileURLWithPath: path).standardizedFileURL.path
        var rest: [String] = []
        while existing != "/" {
            if let real = realpath(existing, nil) {
                defer { free(real) }
                existing = String(cString: real)
                break
            }
            rest.insert((existing as NSString).lastPathComponent, at: 0)
            existing = (existing as NSString).deletingLastPathComponent
        }
        let resolved = rest.reduce(existing) { ($0 as NSString).appendingPathComponent($1) }
        return resolved.lowercased()
    }
}
