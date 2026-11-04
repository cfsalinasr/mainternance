import Foundation
import MainternanceDomain

/// Home's scanner status with the next weekly scan filled in from the current preferences: when the weekly scan is
/// on, `nextScan` is its next slot (`ScanSchedule.nextRun`); when it is off, nil. Everything else is the base
/// provider's, and no scanner stays no scanner.
public struct ScheduledScanStatusProvider: ScanStatusProviding {
    private let base: any ScanStatusProviding
    private let preferences: @Sendable () async -> AppPreferences
    private let now: @Sendable () -> Date
    private let calendar: Calendar

    /// `preferences` should be `ScanScheduler.weeklyPreferences`, so the run it recorded counts at once. The
    /// calendar follows the Mac's time zone as it changes, like the scheduler's.
    public init(
        base: any ScanStatusProviding, preferences: @escaping @Sendable () async -> AppPreferences,
        now: @escaping @Sendable () -> Date = Date.init, calendar: Calendar = .autoupdatingCurrent
    ) {
        self.base = base
        self.preferences = preferences
        self.now = now
        self.calendar = calendar
    }

    public func currentStatus() async -> ScanStatus? {
        guard var status = await base.currentStatus() else { return nil }
        let current = await preferences()
        status.nextScan = current.weeklyScanEnabled
            ? current.schedule.nextRun(now: now(), lastRun: current.lastScheduledRun, calendar: calendar)
            : nil
        return status
    }
}
