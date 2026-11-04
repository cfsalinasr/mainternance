import Foundation
import MainternanceDomain

/// Home's scanner status with the next weekly scan filled in from the current preferences: when the weekly scan is
/// on, `nextScan` is its next slot (`ScanSchedule.nextRun`); when it is off, nil. A slot that is due while the
/// scanner cannot start it is shown as waiting (`weeklyScanWaiting`), never as "now". Everything else is the base
/// provider's, and no scanner stays no scanner.
public struct ScheduledScanStatusProvider: ScanStatusProviding {
    private let base: any ScanStatusProviding
    private let preferences: @Sendable () async -> AppPreferences
    private let scannerCannotStart: @Sendable () async -> Bool
    private let now: @Sendable () -> Date
    private let calendar: Calendar

    /// `preferences` should be `ScanScheduler.weeklyPreferences`, so the run it recorded counts at once;
    /// `scannerCannotStart` is true when the engine is known and cannot scan (`ScannerViewModel.engineCannotScan`).
    /// The calendar follows the Mac's time zone as it changes, like the scheduler's.
    public init(
        base: any ScanStatusProviding, preferences: @escaping @Sendable () async -> AppPreferences,
        scannerCannotStart: @escaping @Sendable () async -> Bool = { false },
        now: @escaping @Sendable () -> Date = Date.init, calendar: Calendar = .autoupdatingCurrent
    ) {
        self.base = base
        self.preferences = preferences
        self.scannerCannotStart = scannerCannotStart
        self.now = now
        self.calendar = calendar
    }

    public func currentStatus() async -> ScanStatus? {
        guard var status = await base.currentStatus() else { return nil }
        let current = await preferences()
        guard current.weeklyScanEnabled else {
            status.nextScan = nil
            return status
        }
        let moment = now()
        let due = current.schedule.isDue(now: moment, lastRun: current.lastScheduledRun, calendar: calendar)
        if due, await scannerCannotStart() {
            status.nextScan = nil
            status.weeklyScanWaiting = true
            return status
        }
        status.nextScan = current.schedule.nextRun(now: moment, lastRun: current.lastScheduledRun, calendar: calendar)
        return status
    }
}
