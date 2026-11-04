import AppKit
import Foundation
import MainternanceDomain

/// The Uninstaller pieces for the whole app: a lister, a leftover finder and a mover over the same folders.
public struct UninstallerServices: Sendable {
    public let lister: any AppListing
    public let finder: any LeftoverFinding
    public let mover: any AppUninstalling

    /// `/Applications` and the owner's `~/Applications`.
    public static var standardApplicationFolders: [URL] {
        // macOS names the folders: the system-wide Applications folder, then the owner's own.
        let manager = FileManager.default
        return manager.urls(for: .applicationDirectory, in: .localDomainMask)
            + manager.urls(for: .applicationDirectory, in: .userDomainMask)
    }

    /// `home` is the owner's home folder. Tests pass a temp home, a temp Applications folder, their own running check
    /// and a `trash` that moves items into a temp folder, so no test touches the real `~/Library`, `/Applications`
    /// or Trash.
    public init(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        applicationFolders: [URL] = UninstallerServices.standardApplicationFolders,
        isRunning: @escaping @Sendable (String) -> Bool = UninstallerServices.isRunning,
        trash: @escaping @Sendable (URL) throws -> Void = CleanupServices.moveToTrash
    ) {
        lister = AppLister(applicationFolders: applicationFolders)
        finder = LeftoverFinder(home: home)
        mover = AppMover(
            home: home, applicationFolders: applicationFolders, isRunning: isRunning, trash: trash,
            isProtected: { ProtectedPaths.isProtected($0) }
        )
    }

    /// Whether an app with this bundle identifier is running now (asks macOS; read-only).
    @Sendable
    public static func isRunning(_ bundleIdentifier: String) -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).isEmpty
    }
}
