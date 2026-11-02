import Foundation

/// Finds the few external tools the scanner is allowed to run (Homebrew and ClamAV) on disk.
///
/// Only the names in `allowedTools` can ever be located, so no caller can use the locator to resolve an arbitrary
/// executable by accident. Results are absolute paths inside the configured candidate directories.
public struct ToolLocator: Sendable {
    /// The only tool names that can be located. Matching is exact and case sensitive.
    public static let allowedTools: Set<String> = ["brew", "clamscan", "freshclam"]

    private let candidates: [String]
    private let isExecutable: @Sendable (String) -> Bool

    public init(
        candidates: [String] = ["/opt/homebrew/bin", "/usr/local/bin"],
        isExecutable: @escaping @Sendable (String) -> Bool = ToolLocator.isRegularExecutable
    ) {
        self.candidates = candidates
        self.isExecutable = isExecutable
    }

    /// The absolute path of `tool` in the first candidate directory that holds an executable by that name,
    /// or nil when the name is not allowed or no candidate has it.
    public func path(for tool: String) -> String? {
        guard Self.allowedTools.contains(tool), !tool.contains("/"), !tool.contains("..") else { return nil }
        for directory in candidates where directory.hasPrefix("/") {
            let base = directory.hasSuffix("/") ? String(directory.dropLast()) : directory
            let candidate = base + "/" + tool
            if isExecutable(candidate) {
                return candidate
            }
        }
        return nil
    }

    /// Default check: an executable that is not a directory (directories carry the execute bit too).
    @Sendable
    public static func isRegularExecutable(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), !isDirectory.boolValue else {
            return false
        }
        return FileManager.default.isExecutableFile(atPath: path)
    }
}
