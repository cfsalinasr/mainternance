import Foundation
import MainternanceDomain
@testable import MainternancePresentation
import Testing

@MainActor
struct AutomationRig {
    let scanner: ScannerRig
    let store: FakePreferencesStore
    let notifications: FakeNotifications
    let clock: TestClock
    let settings: SettingsViewState
    let automation: ScanAutomation

    /// Saved: weekly scan on (Sunday 02:00 UTC, last run a week before), both notification toggles as given.
    static func make(
        alerts: Bool = true, digest: Bool = true, lastRun: Date = utc("2026-10-25 02:00"),
        now: Date = utc("2026-11-01 02:00")
    ) async -> AutomationRig {
        let scanner = await ScannerRig.ready()
        var saved = AppPreferences.defaults
        saved.weeklyScanEnabled = true
        saved.lastScheduledRun = lastRun
        saved.problemAlerts = alerts
        saved.weeklyDigest = digest
        let store = FakePreferencesStore(saved)
        let notifications = FakeNotifications(.allowed)
        let clock = TestClock(now)
        let settings = SettingsViewState(
            preferences: store, loginItem: FakeLoginItem(), notifications: notifications, now: { clock.now }
        )
        let scheduler = ScanScheduler(
            scanner: scanner.model, preferences: store, now: { clock.now }, calendar: utcCalendar,
            sleep: { _ in try await Task.sleep(for: .seconds(3600)) }
        )
        let automation = ScanAutomation(
            scanner: scanner.model, settings: settings, scheduler: scheduler,
            notifier: ScanNotifier(notifications: notifications)
        )
        return AutomationRig(
            scanner: scanner, store: store, notifications: notifications, clock: clock, settings: settings,
            automation: automation
        )
    }

    func finishWith(findings: Int) {
        scanner.engine.configure {
            $0.scanEvents = [.started(scope: .quick), .finished(makeSummary(scope: .quick, findings: findings))]
        }
    }

    func notificationsSent() async {
        await automation.lastNotification?.value
    }
}

@MainActor
struct ScanAutomationTests {
    @Test func beforeSettingsLoadNothingIsScheduled() async {
        let rig = await AutomationRig.make()
        rig.finishWith(findings: 0)
        await rig.automation.scheduler.tick()
        #expect(rig.scanner.engine.scans.isEmpty)
    }

    @Test func loadedSettingsReachTheScheduler() async {
        let rig = await AutomationRig.make()
        rig.finishWith(findings: 0)
        await rig.settings.load()
        await rig.automation.scheduler.tick()
        #expect(rig.scanner.engine.scans == [.quick])
    }

    @Test func aScheduledScanNotifiesOnceEvenWithBothTogglesOn() async {
        let rig = await AutomationRig.make()
        rig.finishWith(findings: 2)
        await rig.settings.load()
        await rig.automation.scheduler.tick()
        await rig.notificationsSent()
        #expect(rig.notifications.posted.map(\.id) == ["weekly-digest"])
        #expect(rig.notifications.posted.first?.title == "Weekly scan finished: 2 files to review")
    }

    @Test func aManualScanWithFindingsPostsAnAlert() async {
        let rig = await AutomationRig.make(digest: false)
        rig.finishWith(findings: 1)
        await rig.settings.load()
        _ = await rig.scanner.model.startScan(.quick)
        await rig.notificationsSent()
        #expect(rig.notifications.posted.map(\.title) == ["Mainternance found 1 file to review"])
    }

    @Test func settingsChangesReachTheNotifier() async {
        let rig = await AutomationRig.make()
        rig.finishWith(findings: 3)
        await rig.settings.load()
        await rig.settings.setProblemAlerts(false)
        _ = await rig.scanner.model.startScan(.quick)
        await rig.notificationsSent()
        #expect(rig.notifications.posted.isEmpty)
    }

    @Test func turningTheWeeklyScanOffReachesTheScheduler() async {
        let rig = await AutomationRig.make()
        rig.finishWith(findings: 0)
        await rig.settings.load()
        await rig.settings.setWeeklyScanEnabled(false)
        await rig.automation.scheduler.tick()
        #expect(rig.scanner.engine.scans.isEmpty)
    }

    @Test func startAndStopControlTheTimer() async {
        let rig = await AutomationRig.make()
        rig.automation.start()
        #expect(rig.automation.scheduler.loop != nil)
        rig.automation.stop()
        #expect(rig.automation.scheduler.loop == nil)
    }

    @Test func wakingTheMacChecksTheSchedule() async {
        let rig = await AutomationRig.make()
        let before = rig.automation.scheduler.tickCount
        rig.automation.macDidWake()
        for _ in 0 ..< 100 where rig.automation.scheduler.tickCount == before {
            await Task.yield()
        }
        #expect(rig.automation.scheduler.tickCount == before + 1)
    }

    // MARK: Settings and the scheduler write the same file

    /// Settings' save is held while the scheduler records its run: when Settings' change lands, the run stays.
    @Test func aSettingsChangeSavedAfterTheScheduledRunKeepsTheRun() async {
        let rig = await AutomationRig.make()
        rig.finishWith(findings: 0)
        await rig.settings.load()
        rig.store.configure { $0.holdNextSave = true }
        var calls = rig.store.saveCalls.makeAsyncIterator()
        let change = Task { await rig.settings.setProblemAlerts(false) }
        _ = await calls.next()
        await rig.automation.scheduler.tick()
        #expect(rig.scanner.engine.scans == [.quick])
        rig.store.releaseSave()
        await change.value
        #expect(rig.store.stored.lastScheduledRun == utc("2026-11-01 02:00"))
        #expect(!rig.store.stored.problemAlerts)
    }

    /// The scheduler's record is held while Settings saves a change: when the record lands, the change stays.
    @Test func aScheduledRunSavedAfterASettingsChangeKeepsTheChange() async {
        let rig = await AutomationRig.make()
        rig.finishWith(findings: 0)
        await rig.settings.load()
        rig.store.configure { $0.holdNextSave = true }
        var calls = rig.store.saveCalls.makeAsyncIterator()
        let tick = Task { await rig.automation.scheduler.tick() }
        _ = await calls.next()
        await rig.settings.setWeeklyDigest(false)
        rig.store.releaseSave()
        await tick.value
        #expect(rig.scanner.engine.scans == [.quick])
        #expect(rig.store.stored.lastScheduledRun == utc("2026-11-01 02:00"))
        #expect(!rig.store.stored.weeklyDigest)
        #expect(rig.store.stored.weeklyScanEnabled)
    }

    /// Moving the day and time through values that already passed this week (as the time picker's arrows do)
    /// never starts a scan; the new time runs from next week on.
    @Test func steppingTheScheduleThroughPassedTimesNeverStartsAScan() async {
        let rig = await AutomationRig.make(lastRun: utc("2026-11-01 02:00"), now: utc("2026-11-04 10:00"))
        rig.finishWith(findings: 0)
        await rig.settings.load()
        await rig.settings.setWeekday(4) // Wednesday: today
        await rig.automation.scheduler.tick()
        for (hour, minute) in [(3, 0), (8, 0), (9, 0), (9, 30), (9, 59), (10, 0)] {
            await rig.settings.setTime(hour: hour, minute: minute)
            await rig.automation.scheduler.tick()
        }
        await rig.settings.setTime(hour: 10, minute: 0) // the same time saved again
        await rig.automation.scheduler.tick()
        #expect(rig.scanner.engine.scans.isEmpty)
        rig.clock.set(utc("2026-11-11 10:00"))
        await rig.automation.scheduler.tick()
        #expect(rig.scanner.engine.scans == [.quick])
    }
}
