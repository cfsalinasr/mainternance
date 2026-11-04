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
    let settings: SettingsViewState
    /// The weekly scheduler and the scan notifications, already connected to Settings and the Scanner.
    let automation: ScanAutomation
    let startup: StartupViewState
    let cleanup: CleanupViewState
    let uninstaller: UninstallerViewState
    /// Tells Home's Cleanup suggestion whether Home is on screen (it measures again in the background only then).
    let homeVisibility: @MainActor (Bool) -> Void
}

@MainActor
enum CompositionRoot {
    /// Builds the app's object graph. There is exactly ONE `ScannerServices` (one quarantine store, one scanner, one
    /// installer): two stores on one folder would overwrite each other, and a second scanner would not know about
    /// the first one's running child process. The metrics provider is created once as well and reused for every
    /// poll: the CPU reader keeps its baseline in it.
    static func make() -> Composition {
        let services = ScannerServices()
        // The startup review baseline sits next to the scanner's files:
        // <Application Support>/Mainternance/startup-review.json. Home counts new items with the read-only counter.
        let startupServices = StartupServices(directory: services.paths.supportDirectory)
        // Cleanup measures the owner's own Caches, Logs, Downloads and DerivedData when its screen appears (never at
        // launch), and moves what the owner confirmed to the real Trash. Home's suggestion uses its last measurement.
        let cleanupServices = CleanupServices()
        let load = LoadOverview(
            snapshots: LiveSystemSnapshotProvider(startup: startupServices.newItemCounter),
            scans: services.statusProvider,
            actions: cleanupServices.estimate
        )
        let scannerModel = ScannerViewModel(
            engine: services.scanner,
            quarantine: services.quarantine,
            statusStore: services.statusStore,
            protectedFolders: services.ownFolders,
            openURL: { NSWorkspace.shared.open($0) }
        )
        // Settings live next to the scanner's files: <Application Support>/Mainternance/preferences.json. One store
        // and one notification service are shared: Settings and the scheduler write the same file.
        let preferences = PreferencesStore(directory: services.paths.supportDirectory)
        let notifications = UserNotificationService()
        let settings = SettingsViewState(
            preferences: preferences, loginItem: LoginItemService(), notifications: notifications
        )
        let automation = ScanAutomation(
            scanner: scannerModel, settings: settings, preferences: preferences, notifications: notifications
        )
        let startup = StartupViewState(
            lister: startupServices.lister, controller: startupServices.controller,
            reviewer: startupServices.reviewer,
            reveal: { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: $0)]) }
        )
        let cleanup = CleanupViewState(scanner: cleanupServices.scanner, mover: cleanupServices.mover)
        let uninstallerServices = UninstallerServices()
        let uninstaller = UninstallerViewState(
            lister: uninstallerServices.lister, finder: uninstallerServices.finder, mover: uninstallerServices.mover
        )
        let estimate = cleanupServices.estimate
        cleanup.onMeasurement = { estimate.record($0) }
        return Composition(
            overview: OverviewViewModel(load: load), scannerModel: scannerModel, scannerServices: services,
            settings: settings, automation: automation, startup: startup, cleanup: cleanup,
            uninstaller: uninstaller, homeVisibility: { estimate.setHomeVisible($0) }
        )
    }

    /// Stops the scanner's child processes (clamscan, brew, freshclam) when the app quits, so none outlives it.
    /// Stops the scheduler as well, so no scheduled scan starts while the app quits.
    static func stopScannerOnQuit(_ services: ScannerServices, automation: ScanAutomation) {
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: nil
        ) { _ in
            // AppKit posts this on the main thread; running it inline keeps the quit hook synchronous.
            MainActor.assumeIsolated { automation.stop() }
            services.terminateNow()
        }
    }

    /// A weekly slot missed while the Mac slept is checked as soon as it wakes.
    static func checkScheduleOnWake(_ automation: ScanAutomation) {
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { automation.macDidWake() }
        }
    }
}
