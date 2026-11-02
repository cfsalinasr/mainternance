import AppKit
import MainternanceData
import MainternanceDomain
import MainternancePresentation

/// Everything the app creates once at launch.
@MainActor
struct Composition {
    let overview: OverviewViewModel
    let scannerModel: ScannerViewModel
    /// Kept so the quit hook can stop a running scan or install.
    let scannerServices: ScannerServices
}

@MainActor
enum CompositionRoot {
    /// Builds the app's object graph. There is exactly ONE `ScannerServices` (one quarantine store, one scanner, one
    /// installer): two stores on one folder would overwrite each other, and a second scanner would not know about
    /// the first one's running child process. The metrics provider is created once as well and reused for every
    /// poll: the CPU reader keeps its baseline in it.
    static func make() -> Composition {
        let services = ScannerServices()
        let load = LoadOverview(
            snapshots: LiveSystemSnapshotProvider(),
            scans: services.statusProvider,
            actions: NoSuggestedActionsProvider()
        )
        let scannerModel = ScannerViewModel(
            engine: services.scanner,
            quarantine: services.quarantine,
            statusStore: services.statusStore,
            protectedFolders: services.ownFolders,
            openURL: { NSWorkspace.shared.open($0) }
        )
        return Composition(
            overview: OverviewViewModel(load: load), scannerModel: scannerModel, scannerServices: services
        )
    }

    /// Stops the scanner's child processes (clamscan, brew, freshclam) when the app quits, so none outlives it.
    static func stopScannerOnQuit(_ services: ScannerServices) {
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: nil
        ) { _ in
            services.terminateNow()
        }
    }
}
