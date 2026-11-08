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

    /// Exempt from the `/usr` protection: macOS itself leaves `/usr/local` to the user and malware hides there.
    private static let exemptTree = "/usr/local"

    /// True when `path` is protected: a system tree, the root, the home folder itself, the running app bundle, or a
    /// folder that holds the running app bundle (moving it would take Mainternance with it).
    public static func isProtected(_ path: String) -> Bool {
        isProtected(path, including: [])
    }

    /// Like `isProtected(_:)`, with extra folders (for example the quarantine folder) protected together with
    /// everything below them and every folder that holds them. Extra folders are never exempt.
    public static func isProtected(_ path: String, including extraTrees: [URL]) -> Bool {
        Resolved(including: extraTrees).isProtected(path)
    }

    /// True when `path` is a folder that holds the running app bundle (an ancestor of it, not the bundle itself).
    @Sendable
    public static func holdsApp(_ path: String) -> Bool {
        Resolved().holdsApp(path)
    }

    /// The same check with the fixed folders (system trees, the exempt tree, the app bundle, the home folder and
    /// any extra folders) resolved once, when it is made; each call then resolves only the path asked about. Gives
    /// exactly what `isProtected(_:including:)` gives, for callers that ask many times (the file walker asks once
    /// per folder). `bundlePath` is the running app bundle; tests pass another one.
    public struct Resolved: Sendable {
        private let extras: [String]
        private let exempt: String?
        private let system: [String]
        private let bundle: String?
        private let home: String?

        public init(including extraTrees: [URL] = [], bundlePath: String = Bundle.main.bundlePath) {
            extras = extraTrees.compactMap { ProtectedPaths.normalize($0.path) }
            exempt = ProtectedPaths.normalize(ProtectedPaths.exemptTree)
            bundle = ProtectedPaths.normalize(bundlePath)
            system = ProtectedPaths.protectedTrees.compactMap(ProtectedPaths.normalize) + [bundle].compactMap(\.self)
            home = ProtectedPaths.normalize(FileManager.default.homeDirectoryForCurrentUser.path)
        }

        /// Protected, or a folder that holds the app bundle or an extra folder.
        public func isProtected(_ path: String) -> Bool {
            guard let candidate = ProtectedPaths.normalize(path) else { return true }
            let held = [bundle].compactMap(\.self) + extras
            return isWithin(candidate) || held.contains { ProtectedPaths.contains(tree: candidate, $0) }
        }

        /// A folder that holds the app bundle (an ancestor of it, not the bundle itself).
        public func holdsApp(_ path: String) -> Bool {
            guard let bundle, let candidate = ProtectedPaths.normalize(path) else { return false }
            return bundle.hasPrefix(candidate == "/" ? "/" : candidate + "/")
        }

        /// Only the protected places and what is below them, not the folders that hold the app or an extra folder.
        /// For walks: a folder that holds the app is entered, and the app inside it is still refused.
        public func isWithinProtected(_ path: String) -> Bool {
            guard let candidate = ProtectedPaths.normalize(path) else { return true }
            return isWithin(candidate)
        }

        private func isWithin(_ candidate: String) -> Bool {
            if candidate == "/" {
                return true
            }
            if extras.contains(where: { ProtectedPaths.contains(tree: $0, candidate) }) {
                return true
            }
            let isExempt = exempt.map { ProtectedPaths.contains(tree: $0, candidate) } ?? false
            if !isExempt, system.contains(where: { ProtectedPaths.contains(tree: $0, candidate) }) {
                return true
            }
            if let bundle, ProtectedPaths.contains(tree: bundle, candidate) {
                return true
            }
            return candidate == home
        }
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
