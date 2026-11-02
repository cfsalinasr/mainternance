import Foundation
import MainternanceDomain

/// The one set of scanner pieces for the whole app. The composition root builds exactly ONE of these: two
/// quarantine stores on one folder would overwrite each other's manifest, and a second scanner or installer would
/// not know about the first one's running child process.
public final class ScannerServices: Sendable {
    public let paths: ClamAVPaths
    public let installer: ClamAVInstaller
    public let scanner: ClamAVScanner
    public let quarantine: QuarantineStore
    public let statusStore: ScanStatusStore
    /// Home's scan status, reading what the Scanner screen persisted.
    public let statusProvider: StoredScanStatusProvider

    public init(
        paths: ClamAVPaths = ClamAVPaths(),
        locator: ToolLocator = ToolLocator(),
        runner: ProcessRunning = SystemProcessRunner(),
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        statusNow: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.paths = paths
        let installer = ClamAVInstaller(locator: locator, runner: runner, paths: paths)
        self.installer = installer
        scanner = ClamAVScanner(
            locator: locator, runner: runner, paths: paths, definitions: DefinitionsStore(paths: paths),
            installer: installer, environment: .init(home: home)
        )
        quarantine = QuarantineStore(directory: paths.quarantineDirectory, now: { Date() })
        let store = ScanStatusStore(file: ScanStatusStore.defaultFile(paths: paths), now: statusNow)
        statusStore = store
        statusProvider = StoredScanStatusProvider(store: store, isEngineInstalled: { installer.isInstalled() })
    }

    /// Folders the Scanner must never take as a custom scan root: the app's own quarantine and ClamAV state.
    public var ownFolders: [URL] {
        [paths.quarantineDirectory, paths.root]
    }

    /// The quit hook: kills a running scan AND a running install or definitions update, synchronously, and forbids
    /// any new start. The app calls it when it terminates; otherwise `clamscan`, `brew` or `freshclam` outlive it.
    public func terminateNow() {
        scanner.terminateNow()
        installer.terminateNow()
        // Detections reported a moment ago may still be waiting for their coalesced write.
        statusStore.flushNow()
    }
}
