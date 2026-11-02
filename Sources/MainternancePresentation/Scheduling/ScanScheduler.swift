import Foundation
import MainternanceDomain

/// Starts the weekly quick scan through the Scanner screen's model while the app runs.
///
/// Rules: nothing happens while the weekly scan is off; a slot runs at most once (`ScanSchedule.isDue`), and its
/// run is recorded (in memory and on disk) BEFORE the scan starts, so a crash during the scan cannot make it run
/// again in a loop; when the scanner cannot start (engine not ready, or a scan, install or quarantine working) the
/// tick is skipped without recording, nothing is queued, and the next tick tries again. A run missed while the app
/// was closed or the Mac asleep is made up once, at the first tick that finds the slot due.
///
/// A timer ticks every 60 s, at `start()`, and when preferences change; the App target also calls `tick()` when
/// the Mac wakes.
@MainActor
public final class ScanScheduler {
    /// The summary of the last scheduled scan that ended with one (completed, cancelled or failed late).
    public private(set) var lastScheduledScanFinished: ScanSummary?
    /// Called after each scheduled scan that ended with a summary; never for scans started by hand. Notifications
    /// come from `ScannerViewModel.onScanCompleted` (which says whether the scan was scheduled), not from here, so
    /// one scan never notifies twice.
    public var onScheduledScanFinished: (@MainActor (ScanSummary) -> Void)?

    private let scanner: ScannerViewModel
    private let preferences: any PreferencesStoring
    private let now: @Sendable () -> Date
    private let calendar: Calendar
    private let sleep: @Sendable (Duration) async throws -> Void
    /// Off until the first `update`.
    private var current: AppPreferences = .defaults
    private var isTicking = false
    private(set) var loop: Task<Void, Never>?
    /// Test seam: how many ticks were asked for.
    private(set) var tickCount = 0

    /// The calendar follows the Mac's time zone as it changes (`autoupdatingCurrent`).
    public init(
        scanner: ScannerViewModel, preferences: any PreferencesStoring,
        now: @escaping @Sendable () -> Date = Date.init, calendar: Calendar = .autoupdatingCurrent,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.scanner = scanner
        self.preferences = preferences
        self.now = now
        self.calendar = calendar
        self.sleep = sleep
    }

    /// Takes new preferences. The newer `lastScheduledRun` wins, so values that do not know about a run recorded
    /// meanwhile cannot make that slot run again. While the timer runs, checks at once.
    public func update(_ preferences: AppPreferences) {
        var next = preferences
        next.lastScheduledRun = Self.later(preferences.lastScheduledRun, current.lastScheduledRun)
        current = next
        if loop != nil {
            Task { await tick() }
        }
    }

    /// Ticks now and then every 60 s until `stop()`. A second call does nothing.
    public func start() {
        guard loop == nil else { return }
        loop = Task { [weak self, sleep] in
            while !Task.isCancelled {
                // No strong reference is held while sleeping, so the timer never keeps the scheduler alive.
                guard self != nil else { return }
                await self?.tick()
                do {
                    try await sleep(.seconds(60))
                } catch {
                    return
                }
            }
        }
    }

    public func stop() {
        loop?.cancel()
        loop = nil
    }

    /// Starts the scheduled scan when its slot is due and the scanner can start; otherwise does nothing.
    public func tick() async {
        tickCount += 1
        guard !isTicking, current.weeklyScanEnabled else { return }
        let moment = now()
        guard current.schedule.isDue(now: moment, lastRun: current.lastScheduledRun, calendar: calendar),
              scanner.canStartScan
        else { return }
        isTicking = true
        defer { isTicking = false }
        current.lastScheduledRun = moment
        await preferences.save(current)
        // The save let other work run: re-check, and give the slot up rather than queue behind a manual scan.
        guard current.weeklyScanEnabled, scanner.canStartScan else { return }
        scanner.startingScheduledScan = true
        let result = await scanner.startScan(.quick)
        scanner.startingScheduledScan = false
        guard let summary = result else { return }
        lastScheduledScanFinished = summary
        onScheduledScanFinished?(summary)
    }

    private static func later(_ first: Date?, _ second: Date?) -> Date? {
        switch (first, second) {
        case let (first?, second?): max(first, second)
        case let (first?, nil): first
        case let (nil, second): second
        }
    }
}
