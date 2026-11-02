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

    // MARK: Launch at login

    @Test func launchAtLoginFollowsTheReturnedStatus() async {
        let rig = SettingsRig()
        await rig.state.setLaunchAtLogin(true)
        #expect(rig.login.requests == [true])
        #expect(rig.state.launchAtLogin)
        #expect(rig.store.stored.launchAtLogin)
        #expect(rig.state.message == nil)
        await rig.state.setLaunchAtLogin(false)
        #expect(!rig.state.launchAtLogin)
        #expect(!rig.store.stored.launchAtLogin)
    }

    @Test func approvalNeededKeepsTheToggleOffAndSaysWhere() async {
        let rig = SettingsRig()
        rig.login.configure { $0.resultStatus = .requiresApproval }
        await rig.state.setLaunchAtLogin(true)
        #expect(rig.state.loginStatus == .requiresApproval)
        #expect(!rig.state.launchAtLogin)
        #expect(!rig.state.current.launchAtLogin)
        #expect(!rig.store.stored.launchAtLogin)
        let message = rig.state.message ?? ""
        #expect(message.contains("System Settings > General > Login Items"))
        #expect(rig.state.notes == [message]) // said once, not twice
    }

    @Test func aRefusalShowsItsMessageAndLeavesTheToggleOff() async {
        let rig = SettingsRig()
        rig.login.configure { $0.fails = true }
        await rig.state.setLaunchAtLogin(true)
        #expect(!rig.state.launchAtLogin)
        #expect(!rig.store.stored.launchAtLogin)
        #expect(rig.state.message == "macOS could not change Launch at login: test refusal")
    }

    @Test func unavailableLoginItemIsExplained() async {
        let rig = SettingsRig()
        rig.login.configure { $0.status = .unavailable }
        await rig.state.load()
        #expect(!rig.state.launchAtLogin)
        #expect(rig.state.loginWarning == SettingsText.loginUnavailable)
        #expect(rig.state.notes.contains(SettingsText.loginUnavailable))
    }

    // MARK: Notifications

    @Test func turningOnAlertsAsksForPermissionOnce() async {
        var stored = AppPreferences.defaults
        stored.problemAlerts = false
        stored.weeklyDigest = false
        let rig = SettingsRig(stored: stored)
        await rig.state.load()
        await rig.state.setProblemAlerts(true)
        await rig.state.setWeeklyDigest(true)
        #expect(rig.notifications.requests == 1)
        #expect(rig.state.notificationAuthorization == .allowed)
        #expect(rig.state.notificationWarning == nil)
    }

    @Test func permissionIsNotAskedWhenAlreadyDecidedOrWhenTurningOff() async {
        let rig = SettingsRig(authorization: .allowed)
        await rig.state.load()
        await rig.state.setProblemAlerts(false)
        await rig.state.setProblemAlerts(true)
        #expect(rig.notifications.requests == 0)
        let undecided = SettingsRig()
        await undecided.state.load()
        await undecided.state.setWeeklyDigest(false)
        #expect(undecided.notifications.requests == 0)
    }

    @Test func deniedPermissionSavesTheChoiceAndWarnsWhereToAllow() async {
        var stored = AppPreferences.defaults
        stored.problemAlerts = false
        let rig = SettingsRig(stored: stored)
        rig.notifications.configure { $0.answer = .denied }
        await rig.state.load()
        await rig.state.setProblemAlerts(true)
        #expect(rig.store.stored.problemAlerts)
        #expect(rig.state.current.problemAlerts)
        #expect(rig.state.notificationAuthorization == .denied)
        let warning = rig.state.notificationWarning ?? ""
        #expect(warning.contains("System Settings > Notifications"))
        #expect(rig.state.notes.contains(warning))
        #expect(rig.state.notes.count == Set(rig.state.notes).count)
    }

    @Test func noNotificationWarningWhenBothNotificationTogglesAreOff() async {
        var stored = AppPreferences.defaults
        stored.problemAlerts = false
        stored.weeklyDigest = false
        let rig = SettingsRig(stored: stored, authorization: .denied)
        await rig.state.load()
        #expect(rig.state.notificationWarning == nil)
        let unavailable = SettingsRig(authorization: .unavailable)
        await unavailable.state.load()
        #expect(unavailable.state.notificationWarning == SettingsText.notificationsUnavailable)
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
        #expect(rig.changed.last?.lastScheduledRun == recorded)
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

/// The Settings words and pickers.
@MainActor
struct SettingsTextTests {
    @Test func scheduleSummaryIsHonestAboutWhenItRuns() async throws {
        let utc = try #require(TimeZone(identifier: "UTC"))
        let british = Locale(identifier: "en_GB")
        let rig = SettingsRig()
        #expect(rig.state.scheduleSummary(locale: british, timeZone: utc) == SettingsText.weeklyScanOff)
        await rig.state.setWeeklyScanEnabled(true)
        #expect(rig.state.scheduleSummary(locale: british, timeZone: utc) == [
            "Weekly quick scan, Sunday 02:00.",
            "Runs only while Mainternance is open; turn on Launch at login to keep it running."
        ].joined(separator: " "))
        await rig.state.setWeekday(2)
        await rig.state.setTime(hour: 14, minute: 5)
        await rig.state.setLaunchAtLogin(true)
        #expect(rig.state.scheduleSummary(locale: british, timeZone: utc)
            == "Weekly quick scan, Monday 14:05. Runs only while Mainternance is open; it opens at login.")
        let american = rig.state.scheduleSummary(locale: Locale(identifier: "en_US"), timeZone: utc)
        #expect(american.hasPrefix("Weekly quick scan, Monday 2:05"))
        #expect(american.contains("PM"))
    }

    @Test func weekdayOptionsCoverOneToSevenWithNames() {
        let options = SettingsRig().state.weekdayOptions(locale: Locale(identifier: "en_US"))
        #expect(options.map(\.value) == Array(1 ... 7))
        #expect(options.first?.name == "Sunday")
        #expect(options.last?.name == "Saturday")
    }

    @Test func timeFromDateRoundTrips() async {
        let rig = SettingsRig()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        let date = calendar.date(from: DateComponents(year: 2026, month: 1, day: 5, hour: 17, minute: 45)) ?? Date()
        await rig.state.setTime(from: date, calendar: calendar)
        #expect(rig.state.hour == 17)
        #expect(rig.state.minute == 45)
        let back = calendar.dateComponents([.hour, .minute], from: rig.state.timeDate(calendar: calendar))
        #expect(back.hour == 17 && back.minute == 45)
    }

    @Test func scheduleInputsClamp() {
        #expect(ScheduleInput.weekday(0) == 1)
        #expect(ScheduleInput.weekday(8) == 7)
        #expect(ScheduleInput.hour(-1) == 0)
        #expect(ScheduleInput.hour(24) == 23)
        #expect(ScheduleInput.minute(-5) == 0)
        #expect(ScheduleInput.minute(60) == 59)
        #expect(ScheduleInput.minute(30) == 30)
    }

    @Test func copyIsPinned() {
        #expect(SettingsText.weeklyScanToggle == "Run a quick scan every week")
        #expect(SettingsText.loginApproval == "Launch at login needs your approval: "
            + "open System Settings > General > Login Items and allow Mainternance.")
        #expect(SettingsText.notificationsDenied == "Notifications are off for Mainternance. "
            + "To get them, allow them in System Settings > Notifications > Mainternance.")
    }
}
