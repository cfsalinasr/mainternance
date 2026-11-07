import Foundation
import MainternanceDomain
@testable import MainternancePresentation
import Synchronization
import Testing

/// A clock a test can move.
final class TestClock: Sendable {
    private let value: Mutex<Date>

    init(_ date: Date) {
        value = Mutex(date)
    }

    func set(_ date: Date) {
        value.withLock { $0 = date }
    }

    var now: Date {
        value.withLock { $0 }
    }
}

/// "yyyy-MM-dd HH:mm" in UTC. 2026-11-01 is a Sunday.
func utc(_ text: String) -> Date {
    let numbers = text.split(whereSeparator: { $0 == "-" || $0 == " " || $0 == ":" }).compactMap { Int($0) }
    let parts = DateComponents(
        timeZone: TimeZone(identifier: "UTC"), year: numbers[0], month: numbers[1], day: numbers[2],
        hour: numbers[3], minute: numbers[4]
    )
    return utcCalendar.date(from: parts) ?? .distantPast
}

let utcCalendar: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
    return calendar
}()

@MainActor
struct SchedulerRig {
    let scanner: ScannerRig
    let store: FakePreferencesStore
    let clock: TestClock
    let scheduler: ScanScheduler
    let finished = Recorded<ScanSummary>()

    /// Weekly scan on, Sunday 02:00 UTC, last run as given; the scanner has checked its (ready) engine unless
    /// `primed` is false (the Scanner screen was never opened, as after a launch at login).
    static func make(
        lastRun: Date?, now: Date, enabled: Bool = true, primed: Bool = true,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) async -> SchedulerRig {
        let scanner = primed ? await ScannerRig.ready() : ScannerRig()
        var prefs = AppPreferences.defaults
        prefs.weeklyScanEnabled = enabled
        prefs.lastScheduledRun = lastRun
        let store = FakePreferencesStore(prefs, log: scanner.log)
        let clock = TestClock(now)
        let scheduler = ScanScheduler(
            scanner: scanner.model, preferences: store, now: { clock.now }, calendar: utcCalendar, sleep: sleep
        )
        scheduler.update(prefs)
        let rig = SchedulerRig(scanner: scanner, store: store, clock: clock, scheduler: scheduler)
        let finished = rig.finished
        scheduler.onScheduledScanFinished = { finished.add($0) }
        rig.scanner.engine.configure {
            $0.scanEvents = [.started(scope: .quick), .finished(makeSummary(scope: .quick, scanned: 12))]
        }
        return rig
    }

    var prefs: AppPreferences {
        var prefs = AppPreferences.defaults
        prefs.weeklyScanEnabled = true
        return prefs
    }
}

@MainActor
struct ScanSchedulerTests {
    @Test func aDisabledScheduleNeverScans() async {
        let rig = await SchedulerRig.make(lastRun: nil, now: utc("2026-11-04 10:00"), enabled: false)
        await rig.scheduler.tick()
        #expect(rig.scanner.engine.scans.isEmpty)
        #expect(rig.store.saves.isEmpty)
    }

    @Test func aDueScanRunsOnceAsQuickAndIsRecordedBeforeItStarts() async {
        let slot = utc("2026-11-01 02:00")
        let rig = await SchedulerRig.make(lastRun: utc("2026-10-25 02:00"), now: slot)
        await rig.scheduler.tick()
        #expect(rig.scanner.engine.scans == [.quick])
        #expect(rig.store.saves.map(\.lastScheduledRun) == [slot])
        #expect(rig.store.stored.weeklyScanEnabled)
        #expect(rig.scanner.log.all == ["save", "scan"]) // recorded first: a crash mid-scan cannot loop
        rig.clock.set(utc("2026-11-01 02:01"))
        await rig.scheduler.tick()
        rig.clock.set(utc("2026-11-07 23:59"))
        await rig.scheduler.tick()
        #expect(rig.scanner.engine.scans == [.quick])
        #expect(rig.store.saves.count == 1)
        rig.clock.set(utc("2026-11-08 02:00"))
        await rig.scheduler.tick()
        #expect(rig.scanner.engine.scans == [.quick, .quick])
    }

    @Test func notYetDueDoesNothing() async {
        let rig = await SchedulerRig.make(lastRun: utc("2026-10-25 02:00"), now: utc("2026-11-01 01:59"))
        await rig.scheduler.tick()
        #expect(rig.scanner.engine.scans.isEmpty)
    }

    @Test func anEngineThatIsNotReadyIsSkippedWithoutRecordingAndRetried() async {
        let rig = await SchedulerRig.make(lastRun: nil, now: utc("2026-11-04 10:00"))
        rig.scanner.engine.configure { $0.status = .notInstalled }
        await rig.scanner.model.refreshStatus()
        await rig.scheduler.tick()
        #expect(rig.scanner.engine.scans.isEmpty)
        #expect(rig.store.saves.isEmpty)
        rig.scanner.engine.configure { $0.status = .ready(definitionsAge: 60) }
        await rig.scanner.model.refreshStatus()
        rig.clock.set(utc("2026-11-04 10:01"))
        await rig.scheduler.tick()
        #expect(rig.scanner.engine.scans == [.quick])
    }

    @Test func aScanAlreadyRunningIsNotStackedOrQueued() async {
        let rig = await SchedulerRig.make(lastRun: nil, now: utc("2026-11-04 10:00"))
        rig.scanner.engine.configure { $0.holdScan = true; $0.scanEvents = [.started(scope: .full)] }
        let manual = Task { await rig.scanner.model.startScan(.full) }
        var calls = rig.scanner.engine.scanCalls.makeAsyncIterator()
        _ = await calls.next()
        await rig.scheduler.tick()
        #expect(rig.scanner.engine.scans == [.full])
        #expect(rig.store.saves.isEmpty)
        rig.scanner.engine.emit(.finished(makeSummary(scope: .full)))
        rig.scanner.engine.finishScan()
        await manual.value
        #expect(rig.scanner.engine.scans == [.full]) // nothing was queued behind it
        #expect(rig.finished.all.isEmpty) // the manual scan is not reported as the scheduled one
    }

    @Test func aMissedRunIsMadeUpOnce() async {
        let rig = await SchedulerRig.make(lastRun: utc("2026-10-18 02:00"), now: utc("2026-11-04 10:00"))
        await rig.scheduler.tick()
        rig.clock.set(utc("2026-11-04 10:01"))
        await rig.scheduler.tick()
        rig.clock.set(utc("2026-11-05 10:00"))
        await rig.scheduler.tick()
        #expect(rig.scanner.engine.scans == [.quick])
    }

    @Test func theClockMovingBackDoesNotStartAScan() async {
        let rig = await SchedulerRig.make(lastRun: utc("2026-11-01 02:00"), now: utc("2026-11-01 01:00"))
        await rig.scheduler.tick()
        rig.clock.set(utc("2026-10-31 12:00"))
        await rig.scheduler.tick()
        rig.clock.set(utc("2026-11-01 02:00")) // back to the slot that already ran
        await rig.scheduler.tick()
        #expect(rig.scanner.engine.scans.isEmpty)
    }

    @Test func theScheduledScanIsReportedButManualScansAreNot() async {
        let rig = await SchedulerRig.make(lastRun: nil, now: utc("2026-11-04 10:00"))
        await rig.scheduler.tick()
        let summary = makeSummary(scope: .quick, scanned: 12)
        #expect(rig.finished.all == [summary])
        #expect(rig.scheduler.lastScheduledScanFinished == summary)
        rig.scanner.engine.configure {
            $0.scanEvents = [.started(scope: .full), .finished(makeSummary(scope: .full, scanned: 99))]
        }
        await rig.scanner.model.startScan(.full)
        #expect(rig.finished.all == [summary])
        #expect(rig.scheduler.lastScheduledScanFinished == summary)
    }

    @Test func olderPreferencesPushedLaterDoNotUndoTheRecordedRun() async {
        let rig = await SchedulerRig.make(lastRun: nil, now: utc("2026-11-04 10:00"))
        await rig.scheduler.tick()
        rig.scheduler.update(rig.prefs) // Settings pushes values that do not know about the run yet
        rig.clock.set(utc("2026-11-04 10:05"))
        await rig.scheduler.tick()
        #expect(rig.scanner.engine.scans == [.quick])
    }

    @Test func stopEndsTheTimerAndNoTickFollows() async {
        let sleeps = AsyncStream.makeStream(of: Void.self)
        let rig = await SchedulerRig.make(lastRun: nil, now: utc("2026-11-04 10:00"), enabled: false) { duration in
            sleeps.continuation.yield()
            try await Task.sleep(for: duration)
        }
        rig.scheduler.start()
        var sleeping = sleeps.stream.makeAsyncIterator()
        _ = await sleeping.next()
        #expect(rig.scheduler.tickCount == 1) // the immediate tick at start
        let loop = rig.scheduler.loop
        rig.scheduler.stop()
        await loop?.value
        #expect(rig.scheduler.tickCount == 1)
        #expect(rig.scheduler.loop == nil)
    }

    @Test func theTimerKeepsTickingUntilStopped() async {
        let sleeps = AsyncStream.makeStream(of: Duration.self)
        let rig = await SchedulerRig.make(lastRun: nil, now: utc("2026-11-04 10:00"), enabled: false) { duration in
            sleeps.continuation.yield(duration)
            await Task.yield()
        }
        rig.scheduler.start()
        rig.scheduler.start() // a second start does not add a second timer
        var sleeping = sleeps.stream.makeAsyncIterator()
        for _ in 0 ..< 3 {
            #expect(await sleeping.next() == .seconds(60))
        }
        let loop = rig.scheduler.loop
        rig.scheduler.stop()
        await loop?.value
        let ticks = rig.scheduler.tickCount
        #expect(ticks >= 3)
        for _ in 0 ..< 20 {
            await Task.yield()
        }
        #expect(rig.scheduler.tickCount == ticks)
    }

    @Test func changedPreferencesAreCheckedAtOnceWhileRunning() async {
        let rig = await SchedulerRig.make(lastRun: nil, now: utc("2026-11-04 10:00"), enabled: false)
        let done = AsyncStream.makeStream(of: ScanSummary.self)
        rig.scheduler.onScheduledScanFinished = { done.continuation.yield($0) }
        rig.scheduler.start()
        rig.scheduler.update(rig.prefs)
        var reports = done.stream.makeAsyncIterator()
        #expect(await reports.next() == makeSummary(scope: .quick, scanned: 12))
        rig.scheduler.stop()
        #expect(rig.scanner.engine.scans == [.quick])
    }

    /// The scheduler writes only its run: a value Settings saved meanwhile is not written back over.
    @Test func theSchedulerWritesOnlyItsRun() async {
        let rig = await SchedulerRig.make(lastRun: nil, now: utc("2026-11-04 10:00"))
        rig.store.configure { $0.stored.problemAlerts = false; $0.stored.schedule.minute = 45 }
        await rig.scheduler.tick()
        #expect(rig.scanner.engine.scans == [.quick])
        #expect(rig.store.stored.lastScheduledRun == utc("2026-11-04 10:00"))
        #expect(!rig.store.stored.problemAlerts)
        #expect(rig.store.stored.schedule.minute == 45)
    }

    /// A recorded run more than a week ahead is not real: it does not block the schedule, and values carrying one
    /// cannot replace a real run recorded in this slot (which would make the slot run twice).
    @Test func aRunRecordedFarAheadIsIgnored() async {
        let now = utc("2026-11-04 10:00")
        let rig = await SchedulerRig.make(lastRun: now.addingTimeInterval(30 * 86400), now: now)
        await rig.scheduler.tick()
        #expect(rig.scanner.engine.scans == [.quick])
        var bogus = rig.prefs
        bogus.lastScheduledRun = now.addingTimeInterval(60 * 86400)
        rig.scheduler.update(bogus)
        rig.clock.set(utc("2026-11-04 10:05"))
        await rig.scheduler.tick()
        #expect(rig.scanner.engine.scans == [.quick])
    }
}
