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
        return Composition(
            overview: OverviewViewModel(load: load), scannerModel: scannerModel, scannerServices: services,
            settings: settings, automation: automation
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
