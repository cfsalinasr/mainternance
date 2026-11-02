import Foundation

/// Where the app keeps its own ClamAV state. Pure URL math: nothing here touches the disk.
///
/// The app never uses Homebrew's config or database; it owns `root` and passes these paths to the tools explicitly.
public struct ClamAVPaths: Sendable, Equatable {
    /// `~/Library/Application Support/Mainternance` by default.
    public let supportDirectory: URL

    public init(supportDirectory: URL = ClamAVPaths.defaultSupportDirectory) {
        self.supportDirectory = supportDirectory
    }

    public static var defaultSupportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Mainternance", isDirectory: true)
    }

    /// `<support>/ClamAV`: everything the installer writes lives below this directory.
    public var root: URL {
        supportDirectory.appendingPathComponent("ClamAV", isDirectory: true)
    }

    public var databaseDirectory: URL {
        root.appendingPathComponent("database", isDirectory: true)
    }

    public var freshclamConfig: URL {
        root.appendingPathComponent("freshclam.conf", isDirectory: false)
    }

    /// `<support>/Quarantine`, a sibling of `root` (used by the quarantine store).
    public var quarantineDirectory: URL {
        supportDirectory.appendingPathComponent("Quarantine", isDirectory: true)
    }
}
