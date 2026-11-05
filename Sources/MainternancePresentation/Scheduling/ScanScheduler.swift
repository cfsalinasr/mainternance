import Foundation
import MainternanceDomain

/// Starts the weekly quick scan through the Scanner screen's model while the app runs.
///
/// Rules: nothing happens while the weekly scan is off; a slot runs at most once (`ScanSchedule.isDue`), and its
/// run is recorded (in memory and on disk) BEFORE the scan starts, so a crash during the scan cannot make it run
/// again in a loop. Each due tick first re-reads the engine's status (the Scanner screen may never have opened, as
/// after a launch at login, or ClamAV may have changed since it did); when the scanner cannot start (engine not
/// ready, or a scan, install or quarantine working) the tick is skipped without recording, nothing is queued, and
/// the next tick tries again. Definitions older than a week are updated first; if that fails the scan still runs,
/// its result says how old they are, and the Scanner screen keeps saying why the update failed; if the update left
/// the engine unable to scan, no scan starts. That scan, like one the engine refused before it started, gives its
/// slot back once (in memory: the record on disk stays, so a restart does not retry), so the next tick retries and
/// a scanner that always refuses cannot start a scan every minute. A run missed while the app was closed or the Mac
/// asleep is made up once, at the first tick that finds the slot due.
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
    /// Called after each run is recorded with whether it reached the disk. A run that could not be saved still
    /// counts for this session (it is held in memory, so the slot never runs twice while the app runs), but it may
    /// run again after a restart: Settings says so.
    public var onRunRecorded: (@MainActor (_ saved: Bool) -> Void)?

    private let scanner: ScannerViewModel
    private let preferences: any PreferencesStoring
    private let now: @Sendable () -> Date
    private let calendar: Calendar
    private let sleep: @Sendable (Duration) async throws -> Void
    /// Off until the first `update`.
    private var current: AppPreferences = .defaults
    /// False until the first `update`: `weeklyPreferences` reads the store until then.
    private var hasPreferences = false
    /// A recorded run given back after a scan that never started, and the slot it was in: values pushed later
    /// that carry it (Settings writes through the same store) do not take the slot away again.
    private var withdrawn: (run: Date, slot: Date)?
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

    /// Takes new preferences. The newer valid `lastScheduledRun` wins (`ScanSchedule.laterRun`), so values that do
    /// not know about a run recorded meanwhile, or carry one far in the future, cannot make that slot run again.
    /// While the timer runs, checks at once.
    public func update(_ preferences: AppPreferences) {
        var next = preferences
        var incoming = preferences.lastScheduledRun
        if let withdrawn, incoming == withdrawn.run {
            incoming = nil
        }
        next.lastScheduledRun = ScanSchedule.laterRun(incoming, current.lastScheduledRun, now: now())
        current = next
        hasPreferences = true
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

    /// The values the schedule follows, including the run it recorded: what it holds once Settings reported them,
    /// and until then what the store has saved (the defaults would say the weekly scan is off).
    public func weeklyPreferences() async -> AppPreferences {
        hasPreferences ? current : await preferences.load()
    }

    /// Starts the scheduled scan when its slot is due and the scanner can start; otherwise does nothing.
    public func tick() async {
        tickCount += 1
        guard !isTicking, current.weeklyScanEnabled else { return }
        let moment = now()
        guard current.schedule.isDue(now: moment, lastRun: current.lastScheduledRun, calendar: calendar) else { return }
        isTicking = true
        defer { isTicking = false }
        await scanner.refreshEngineStatus()
        guard current.weeklyScanEnabled, scanner.canStartScan else { return }
        let previousRun = current.lastScheduledRun
        await record(moment)
        // The save let other work run: re-check, and give the slot up rather than queue behind a manual scan.
        guard current.weeklyScanEnabled, scanner.canStartScan else { return }
        var updateFailure: String?
        if scanner.staleDefinitionsDays != nil {
            await scanner.updateDefinitions()
            updateFailure = scanner.errorMessage
            guard current.weeklyScanEnabled else { return }
            guard scanner.canStartScan else {
                // The update left the engine unusable (definitions removed or damaged): no scan started.
                giveBack(moment, previousRun: previousRun)
                return
            }
        }
        scanner.startingScheduledScan = true
        let result = await scanner.runScan(.quick)
        scanner.startingScheduledScan = false
        if let updateFailure {
            scanner.noteScheduledUpdateFailure(updateFailure)
        }
        if !result.began {
            giveBack(moment, previousRun: previousRun)
        }
        guard let summary = result.summary else { return }
        lastScheduledScanFinished = summary
        onScheduledScanFinished?(summary)
    }

    /// Only the run is written (one locked read-modify-write): Settings owns every other field in the file.
    private func record(_ moment: Date) async {
        current.lastScheduledRun = moment
        let written = await preferences.update { $0.lastScheduledRun = moment }
        current.lastScheduledRun = ScanSchedule.laterRun(
            current.lastScheduledRun, written.preferences.lastScheduledRun, now: moment
        )
        onRunRecorded?(written.saved)
    }

    /// Once per slot: a second refusal in the same slot keeps the run, so the next try is next week.
    private func giveBack(_ run: Date, previousRun: Date?) {
        let slot = current.schedule.slotStart(containing: run, calendar: calendar)
        guard withdrawn?.slot != slot, current.lastScheduledRun == run else { return }
        withdrawn = (run, slot)
        current.lastScheduledRun = previousRun
    }
}
