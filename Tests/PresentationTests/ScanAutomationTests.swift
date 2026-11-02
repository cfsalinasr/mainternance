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
    static func make(alerts: Bool = true, digest: Bool = true) async -> AutomationRig {
        let scanner = await ScannerRig.ready()
        var saved = AppPreferences.defaults
        saved.weeklyScanEnabled = true
        saved.lastScheduledRun = utc("2026-10-25 02:00")
        saved.problemAlerts = alerts
        saved.weeklyDigest = digest
        let store = FakePreferencesStore(saved)
        let notifications = FakeNotifications(.allowed)
        let clock = TestClock(utc("2026-11-01 02:00"))
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
}
