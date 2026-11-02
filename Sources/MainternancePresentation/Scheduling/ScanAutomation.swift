import Foundation
import MainternanceDomain

/// Connects Settings, the weekly scheduler and the notifier to the Scanner screen's model.
///
/// Settings changes (and the values `SettingsViewState.load()` reads) reach both the scheduler and the notifier.
/// Notifications come only from `ScannerViewModel.onScanCompleted`, which covers manual and scheduled scans and says
/// which one it was; the scheduler's own `onScheduledScanFinished` is left alone, so one scan never notifies twice.
@MainActor
public final class ScanAutomation {
    public let scheduler: ScanScheduler
    public let notifier: ScanNotifier
    /// Test seam: the notification work for the last finished scan.
    private(set) var lastNotification: Task<Void, Never>?

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
        self.scheduler = scheduler
        self.notifier = notifier
        settings.onChange = { [scheduler, notifier] preferences in
            scheduler.update(preferences)
            notifier.update(preferences)
        }
        scanner.onScanCompleted = { [weak self, notifier] completion in
            self?.lastNotification = Task { await notifier.scanCompleted(completion) }
        }
    }

    /// Starts the 60 s timer (it ticks at once). Call after `settings.load()` was started; until preferences arrive
    /// the scheduler holds the defaults, where the weekly scan is off.
    public func start() {
        scheduler.start()
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
