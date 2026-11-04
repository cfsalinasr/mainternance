import Foundation
import MainternanceDomain

/// Connects Settings, the weekly scheduler and the notifier to the Scanner screen's model.
///
/// Settings changes (and the values `SettingsViewState.load()` reads) reach both the scheduler and the notifier.
/// Notifications come only from `ScannerViewModel.onScanCompleted` and `onScanFailed`, which cover manual and
/// scheduled scans and say which one it was; the scheduler's own `onScheduledScanFinished` is left alone, so one
/// scan never notifies twice.
@MainActor
public final class ScanAutomation {
    public let scheduler: ScanScheduler
    public let notifier: ScanNotifier
    private let scanner: ScannerViewModel
    /// Test seam: the notification work for the last finished scan.
    private(set) var lastNotification: Task<Void, Never>?
    /// Test seam: the engine status check made at `start()`.
    private(set) var launchCheck: Task<Void, Never>?

    /// `preferences` must be the same store Settings saves to: the scheduler records its runs there.
    public convenience init(
        scanner: ScannerViewModel, settings: SettingsViewState, preferences: any PreferencesStoring,
        notifications: any NotificationPosting
    ) {
        self.init(
            scanner: scanner, settings: settings,
            scheduler: ScanScheduler(scanner: scanner, preferences: preferences),
            notifier: ScanNotifier(notifications: notifications)
        )
    }

    init(scanner: ScannerViewModel, settings: SettingsViewState, scheduler: ScanScheduler, notifier: ScanNotifier) {
        self.scanner = scanner
        self.scheduler = scheduler
        self.notifier = notifier
        settings.onChange = { [scheduler, notifier] preferences in
            scheduler.update(preferences)
            notifier.update(preferences)
        }
        scanner.onScanCompleted = { [weak self, notifier] completion in
            self?.lastNotification = Task { await notifier.scanCompleted(completion) }
        }
        scanner.onScanFailed = { [weak self, notifier] failure in
            self?.lastNotification = Task { await notifier.scanFailed(failure) }
        }
    }

    /// Reads the engine status and the saved scan results once (the app may start at login with the window closed,
    /// so the Scanner screen may never ask), then starts the 60 s timer (it ticks at once; each due tick re-reads the
    /// engine status itself). Call after `settings.load()` was started; until preferences arrive the scheduler holds
    /// the defaults, where the weekly scan is off.
    public func start() {
        if launchCheck == nil {
            launchCheck = Task { [scanner] in await scanner.refreshStatus() }
        }
        scheduler.start()
    }

    /// Home's scanner status with the next weekly scan filled in from what the scheduler follows.
    public func statusWithNextScan(_ base: any ScanStatusProviding) -> any ScanStatusProviding {
        Self.statusWithNextScan(base, scanner: scanner, scheduler: scheduler)
    }

    static func statusWithNextScan(
        _ base: any ScanStatusProviding, scanner: ScannerViewModel, scheduler: ScanScheduler
    ) -> any ScanStatusProviding {
        ScheduledScanStatusProvider(
            base: base, preferences: { [scheduler] in await scheduler.weeklyPreferences() },
            scannerCannotStart: { [scanner] in await scanner.engineCannotScan }
        )
    }

    /// The Mac woke: a slot missed while asleep is checked now rather than at the next timer tick.
    public func macDidWake() {
        Task { [scheduler] in await scheduler.tick() }
    }

    /// The app quits: no new scheduled scan starts.
    public func stop() {
        scheduler.stop()
    }
}
