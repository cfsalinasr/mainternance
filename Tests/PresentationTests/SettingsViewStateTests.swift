import Foundation
import MainternanceDomain
@testable import MainternancePresentation
import Testing

@MainActor
struct SettingsRig {
    let store: FakePreferencesStore
    let login = FakeLoginItem()
    let notifications: FakeNotifications
    let state: SettingsViewState
    let changes = Recorded<AppPreferences>()
    nonisolated static let now = Date(timeIntervalSince1970: 1_800_000_000)

    init(stored: AppPreferences = .defaults, authorization: NotificationAuthorization = .notDetermined) {
        store = FakePreferencesStore(stored)
        notifications = FakeNotifications(authorization)
        state = SettingsViewState(
            preferences: store, loginItem: login, notifications: notifications, now: { SettingsRig.now }
        )
        let changes = changes
        state.onChange = { changes.add($0) }
    }

    var changed: [AppPreferences] {
        changes.all
    }
}

@MainActor
struct SettingsViewStateTests {
    private var saved: AppPreferences {
        var prefs = AppPreferences.defaults
        prefs.weeklyScanEnabled = true
        prefs.schedule = ScanSchedule(weekday: 4, hour: 21, minute: 30)
        prefs.problemAlerts = false
        prefs.lastScheduledRun = Date(timeIntervalSince1970: 1_799_000_000)
        return prefs
    }

    // MARK: Loading

    @Test func loadingShowsTheSavedValuesAndTheRealStatuses() async {
        let rig = SettingsRig(stored: saved, authorization: .allowed)
        rig.login.configure { $0.status = .enabled }
        await rig.state.load()
        var expected = saved
        expected.launchAtLogin = true
        #expect(rig.state.current == expected)
        #expect(rig.state.loginStatus == .enabled)
        #expect(rig.state.launchAtLogin)
        #expect(rig.state.notificationAuthorization == .allowed)
        #expect(rig.state.weekday == 4 && rig.state.hour == 21 && rig.state.minute == 30)
        #expect(rig.state.scheduleControlsEnabled)
        #expect(rig.changed == [expected]) // the loaded values reach the scheduler and notifier
        #expect(rig.store.saves.isEmpty) // loading writes nothing
    }

    @Test func aSavedLaunchAtLoginThatMacOSDoesNotHaveIsShownOff() async {
        var stored = saved
        stored.launchAtLogin = true
        let rig = SettingsRig(stored: stored)
        rig.login.configure { $0.status = .disabled }
        await rig.state.load()
        #expect(!rig.state.launchAtLogin)
        #expect(!rig.state.current.launchAtLogin)
    }

    @Test func refreshStatusRereadsWithoutSaving() async {
        let rig = SettingsRig(authorization: .allowed)
        await rig.state.load()
        rig.login.configure { $0.status = .requiresApproval }
        rig.notifications.configure { $0.authorization = .denied }
        await rig.state.refreshStatus()
        #expect(rig.state.loginStatus == .requiresApproval)
        #expect(rig.state.notificationAuthorization == .denied)
        #expect(rig.store.saves.isEmpty)
    }

    // MARK: Saving

    @Test func everySetterPersistsAndReportsTheChange() async {
        let rig = SettingsRig(authorization: .allowed)
        await rig.state.setWeeklyScanEnabled(true)
        await rig.state.setWeekday(3)
        await rig.state.setTime(hour: 8, minute: 15)
        await rig.state.setProblemAlerts(false)
        await rig.state.setWeeklyDigest(false)
        await rig.state.setLaunchAtLogin(true)
        var expected = AppPreferences.defaults
        expected.weeklyScanEnabled = true
        expected.schedule = ScanSchedule(weekday: 3, hour: 8, minute: 15)
        expected.problemAlerts = false
        expected.weeklyDigest = false
        expected.launchAtLogin = true
        expected.lastScheduledRun = SettingsRig.now
        #expect(rig.store.stored == expected)
        #expect(rig.store.saves.count == 6)
        #expect(rig.changed.count == 6)
        #expect(rig.changed.last == expected)
        #expect(rig.state.current == expected)
    }

    @Test func outOfRangeScheduleValuesAreClamped() async {
        let rig = SettingsRig()
        await rig.state.setWeekday(99)
        await rig.state.setTime(hour: -3, minute: 75)
        #expect(rig.state.current.schedule == ScanSchedule(weekday: 7, hour: 0, minute: 59))
        #expect(rig.store.stored.schedule == ScanSchedule(weekday: 7, hour: 0, minute: 59))
        await rig.state.setWeekday(0)
        #expect(rig.state.weekday == 1)
    }

    @Test func twoQuickChangesEndWithTheLastValueOnDisk() async {
        let rig = SettingsRig()
        rig.store.configure { $0.holdNextSave = true }
        var calls = rig.store.saveCalls.makeAsyncIterator()
        let first = Task { await rig.state.setWeekday(3) }
        _ = await calls.next()
        let second = Task { await rig.state.setWeekday(5) }
        for _ in 0 ..< 50 {
            await Task.yield()
        }
        rig.store.releaseSave()
        await first.value
        await second.value
        #expect(rig.store.stored.schedule.weekday == 5)
        #expect(rig.store.saves.map(\.schedule.weekday) == [3, 5])
    }

    /// Changing the day or time (or choosing the same one again) must never start a scan at once for a time that
    /// already passed this week: the change marks the current week as done, keeping a later recorded run.
    @Test func changingTheScheduleMarksTheCurrentWeekAsDone() async {
        var stored = saved
        stored.lastScheduledRun = SettingsRig.now.addingTimeInterval(-30 * 86400)
        let rig = SettingsRig(stored: stored)
        await rig.state.load()
        await rig.state.setWeekday(2)
        #expect(rig.store.stored.lastScheduledRun == SettingsRig.now)
        #expect(rig.state.current.lastScheduledRun == SettingsRig.now)
        #expect(rig.changed.last?.lastScheduledRun == SettingsRig.now) // the scheduler hears it before the save
        var ahead = saved
        ahead.lastScheduledRun = SettingsRig.now.addingTimeInterval(3600)
        let later = SettingsRig(stored: ahead)
        await later.state.load()
        await later.state.setTime(hour: later.state.hour, minute: later.state.minute) // the same time again
        #expect(later.store.stored.lastScheduledRun == ahead.lastScheduledRun)
    }

    /// A recorded run far in the future is not real: turning the scan on or changing the time replaces it with now.
    @Test func aFarFutureRecordedRunIsReplacedByNow() async {
        var stored = AppPreferences.defaults
        stored.lastScheduledRun = SettingsRig.now.addingTimeInterval(60 * 86400)
        let rig = SettingsRig(stored: stored)
        await rig.state.load()
        await rig.state.setWeeklyScanEnabled(true)
        #expect(rig.state.current.lastScheduledRun == SettingsRig.now)
        await rig.state.setTime(hour: 4, minute: 0)
        #expect(rig.state.current.lastScheduledRun == SettingsRig.now)
    }

    /// The scheduler records its runs in the same file; a Settings change must not erase that record, or the
    /// weekly scan would run again in the same week.
    @Test func savingKeepsAScheduledRunRecordedMeanwhile() async {
        let rig = SettingsRig(stored: saved)
        await rig.state.load()
        let recorded = Date(timeIntervalSince1970: 1_800_500_000)
        rig.store.configure { $0.stored.lastScheduledRun = recorded }
        await rig.state.setProblemAlerts(true)
        #expect(rig.store.stored.lastScheduledRun == recorded)
        #expect(rig.state.current.lastScheduledRun == recorded)
    }

    /// The scheduler also writes this file: it must hold the new values before the save runs, or a scheduled run
    /// recorded meanwhile could write the old values back.
    @Test func changesAreReportedBeforeTheyAreSaved() async {
        let rig = SettingsRig()
        rig.store.configure { $0.holdNextSave = true }
        var calls = rig.store.saveCalls.makeAsyncIterator()
        let change = Task { await rig.state.setWeekday(6) }
        _ = await calls.next()
        #expect(rig.changed.last?.schedule.weekday == 6)
        #expect(rig.store.saves.isEmpty)
        rig.store.releaseSave()
        await change.value
        #expect(rig.changed.count == 1)
    }

    /// Turning the weekly scan on must not start a scan at once for a time that already passed this week: the
    /// first scheduled scan runs at the next scheduled time.
    @Test func turningTheWeeklyScanOnMarksTheCurrentWeekAsDone() async {
        let rig = SettingsRig()
        await rig.state.setWeeklyScanEnabled(true)
        #expect(rig.store.stored.lastScheduledRun == SettingsRig.now)
        #expect(rig.store.stored.weeklyScanEnabled)
        var later = AppPreferences.defaults
        later.weeklyScanEnabled = true
        later.lastScheduledRun = SettingsRig.now.addingTimeInterval(3600)
        let alreadyOn = SettingsRig(stored: later)
        await alreadyOn.state.load()
        await alreadyOn.state.setWeeklyScanEnabled(true) // already on: nothing is reset
        #expect(alreadyOn.store.stored.lastScheduledRun == later.lastScheduledRun)
        await alreadyOn.state.setWeeklyScanEnabled(false)
        #expect(!alreadyOn.state.scheduleControlsEnabled)
    }
}
