import Foundation
import MainternanceDomain
import Observation

/// Pure range checks for the scan schedule inputs.
enum ScheduleInput {
    static func weekday(_ value: Int) -> Int {
        min(max(value, 1), 7)
    }

    static func hour(_ value: Int) -> Int {
        min(max(value, 0), 23)
    }

    static func minute(_ value: Int) -> Int {
        min(max(value, 0), 59)
    }
}

struct WeekdayOption: Equatable, Identifiable {
    let value: Int
    let name: String

    var id: Int {
        value
    }
}

/// Every user-visible Settings string, pinned by tests.
enum SettingsText {
    static let launchAtLogin = "Launch at login"
    static let weeklyScanToggle = "Run a quick scan every week"
    static let problemAlerts = "Problem alerts"
    static let problemAlertsHint = "A notification when a scan finds something to review"
    static let weeklyDigest = "Weekly digest"
    static let weeklyDigestHint = "A notification with the result when a weekly scan finishes"
    static let weeklyScanOff = "The weekly quick scan is off."
    static let runsWhileOpen = "It runs only while Mainternance is open; turn on Launch at login to keep it running."
    static let runsWhileOpenAtLogin = "It runs only while Mainternance is open; it opens at login."
    static let runsOnceApproved = [
        "It runs only while Mainternance is open;",
        "it opens at login once you allow it in System Settings > General > Login Items."
    ].joined(separator: " ")
    static let missedRun =
        "If the Mac is asleep or Mainternance is closed at that time, it runs the next time Mainternance runs."
    static let allowNotifications = "Allow notifications to receive these"
    static let allowNotificationsButton = "Allow Notifications"
    static let loginApproval = [
        "Launch at login needs your approval:",
        "open System Settings > General > Login Items and allow Mainternance."
    ].joined(separator: " ")
    static let loginUnavailable = [
        "Launch at login is not available here:",
        "it works when Mainternance runs as an app, ideally from the Applications folder."
    ].joined(separator: " ")
    static let notificationsDenied = [
        "Notifications are off for Mainternance.",
        "To get them, allow them in System Settings > Notifications > Mainternance."
    ].joined(separator: " ")
    static let notificationsUnavailable =
        "Notifications are not available here: they work when Mainternance runs as an app."
}

/// The live Settings screen. Values are saved through `PreferencesStoring`; "Launch at login" and the notification
/// permission always show what macOS reports, never what was asked for.
///
/// Each change is written with `PreferencesStoring.update`, which changes only the fields that change touched in
/// one locked read-modify-write; the scheduler records its runs in the same file the same way, so neither can write
/// back an old value of the other's fields. Changes are written one after another in the order they were made.
///
/// Notification permission is only ever requested from an action here (turning a toggle on, or the "Allow
/// Notifications" button), never from a background event.
@MainActor
@Observable
public final class SettingsViewState {
    public private(set) var current: AppPreferences = .defaults
    public private(set) var loginStatus: LoginItemStatus
    /// `notDetermined` until the first read finished.
    public private(set) var notificationAuthorization: NotificationAuthorization = .notDetermined
    /// The result of the last action when it needs words (an error, or where to approve something).
    public private(set) var message: String?
    /// Called with the new values after each load and at each change, before it is saved (the scheduler and the
    /// notifier listen).
    @ObservationIgnored public var onChange: (@MainActor (AppPreferences) -> Void)?

    @ObservationIgnored private let preferences: any PreferencesStoring
    @ObservationIgnored private let loginItem: any LoginItemControlling
    @ObservationIgnored private let notifications: any NotificationPosting
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private var pendingSave: Task<Date?, Never>?
    @ObservationIgnored private var askedForPermission = false
    /// False until the permission was read once, so nothing is claimed about it before.
    private var authorizationKnown = false

    public init(
        preferences: any PreferencesStoring, loginItem: any LoginItemControlling,
        notifications: any NotificationPosting, now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.preferences = preferences
        self.loginItem = loginItem
        self.notifications = notifications
        self.now = now
        loginStatus = loginItem.status()
    }

    // MARK: - Derived state

    /// The toggle shows the real login-item state: on when macOS has it enabled or registered and waiting for the
    /// owner's approval (with a note saying where), so turning it off can unregister it.
    var launchAtLogin: Bool {
        loginStatus == .enabled || loginStatus == .requiresApproval
    }

    var weekday: Int {
        current.schedule.weekday
    }

    var hour: Int {
        current.schedule.hour
    }

    var minute: Int {
        current.schedule.minute
    }

    /// The day and time pickers work only while the weekly scan is on.
    var scheduleControlsEnabled: Bool {
        current.weeklyScanEnabled
    }

    var loginWarning: String? {
        switch loginStatus {
        case .requiresApproval: SettingsText.loginApproval
        case .unavailable: SettingsText.loginUnavailable
        case .enabled, .disabled: nil
        }
    }

    /// Shown only while a notification toggle is on: a blocked permission matters only then.
    var notificationWarning: String? {
        guard current.problemAlerts || current.weeklyDigest else { return nil }
        switch notificationAuthorization {
        case .denied: return SettingsText.notificationsDenied
        case .unavailable: return SettingsText.notificationsUnavailable
        case .notDetermined, .allowed: return nil
        }
    }

    /// Shown with the "Allow Notifications" button while macOS has never been asked and a notification toggle is
    /// on (a fresh install has both on).
    var notificationPermissionNote: String? {
        guard authorizationKnown, notificationAuthorization == .notDetermined,
              current.problemAlerts || current.weeklyDigest
        else { return nil }
        return SettingsText.allowNotifications
    }

    /// The lines shown under the controls, each once.
    var notes: [String] {
        var seen: [String] = []
        for note in [loginWarning, notificationWarning, message].compactMap(\.self) where !seen.contains(note) {
            seen.append(note)
        }
        return seen
    }

    // MARK: - Loading

    /// Reads the saved values and the real statuses, then reports them through `onChange`. Writes nothing.
    public func load() async {
        let loaded = await preferences.load()
        loginStatus = loginItem.status()
        await readAuthorization()
        current = loaded
        current.launchAtLogin = launchAtLogin
        onChange?(current)
    }

    /// Re-reads what macOS reports (the owner may have changed it in System Settings). Writes nothing. An approval
    /// note from an earlier attempt goes once approval is no longer pending.
    public func refreshStatus() async {
        loginStatus = loginItem.status()
        if message == SettingsText.loginApproval, loginStatus != .requiresApproval {
            message = nil
        }
        current.launchAtLogin = launchAtLogin
        await readAuthorization()
    }

    private func readAuthorization() async {
        notificationAuthorization = await notifications.authorization()
        authorizationKnown = true
    }

    // MARK: - Changes

    public func setLaunchAtLogin(_ enabled: Bool) async {
        message = nil
        do {
            loginStatus = try loginItem.setEnabled(enabled)
            if loginStatus == .requiresApproval {
                message = SettingsText.loginApproval
            }
        } catch {
            loginStatus = loginItem.status()
            message = error.localizedDescription
        }
        let shown = launchAtLogin
        await commit { $0.launchAtLogin = shown }
    }

    /// Turning it on marks the current week as done, so the first scheduled scan runs at the next scheduled time
    /// rather than at once for a time that already passed. The notification permission is re-read so the note
    /// asking for it shows when it is still undecided.
    public func setWeeklyScanEnabled(_ enabled: Bool) async {
        let markDone = enabled && !current.weeklyScanEnabled
        let moment = now()
        await commit { prefs in
            prefs.weeklyScanEnabled = enabled
            if markDone {
                Self.markCurrentWeekDone(&prefs, at: moment)
            }
        }
        if enabled {
            await readAuthorization()
        }
    }

    /// Like turning the scan on, a new day (or the same one chosen again) marks the current week as done: a time
    /// that already passed this week never starts a scan at once.
    public func setWeekday(_ value: Int) async {
        let day = ScheduleInput.weekday(value)
        let moment = now()
        await commit { prefs in
            prefs.schedule.weekday = day
            Self.markCurrentWeekDone(&prefs, at: moment)
        }
    }

    /// See `setWeekday`: each step of the time picker marks the current week as done.
    public func setTime(hour: Int, minute: Int) async {
        let hour = ScheduleInput.hour(hour)
        let minute = ScheduleInput.minute(minute)
        let moment = now()
        await commit { prefs in
            prefs.schedule.hour = hour
            prefs.schedule.minute = minute
            Self.markCurrentWeekDone(&prefs, at: moment)
        }
    }

    /// The recorded run becomes `moment` unless a later valid one is already recorded.
    private nonisolated static func markCurrentWeekDone(_ prefs: inout AppPreferences, at moment: Date) {
        prefs.lastScheduledRun = ScanSchedule.laterRun(prefs.lastScheduledRun, moment, now: moment)
    }

    func setTime(from date: Date, calendar: Calendar = .current) async {
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        await setTime(hour: parts.hour ?? hour, minute: parts.minute ?? minute)
    }

    public func setProblemAlerts(_ enabled: Bool) async {
        await commit { $0.problemAlerts = enabled }
        if enabled {
            await askForPermissionIfUndecided()
        }
    }

    public func setWeeklyDigest(_ enabled: Bool) async {
        await commit { $0.weeklyDigest = enabled }
        if enabled {
            await askForPermissionIfUndecided()
        }
    }

    /// The "Allow Notifications" button. macOS shows its prompt only while undecided.
    public func requestNotificationPermission() async {
        askedForPermission = true
        notificationAuthorization = await notifications.requestAuthorization()
        authorizationKnown = true
    }

    /// Turning a toggle on asks at most once per launch, and only while undecided.
    private func askForPermissionIfUndecided() async {
        await readAuthorization()
        guard notificationAuthorization == .notDetermined, !askedForPermission else { return }
        await requestNotificationPermission()
    }

    /// Applies `change` to the shown values and reports them at once (the scheduler and the notifier must hold
    /// them before anything is written), then writes the same change through `update` after every earlier write
    /// finished. A run the scheduler recorded meanwhile comes back with the result and is kept.
    private func commit(_ change: @escaping @Sendable (inout AppPreferences) -> Void) async {
        change(&current)
        onChange?(current)
        let previous = pendingSave
        let store = preferences
        let write = Task<Date?, Never> {
            _ = await previous?.value
            return await store.update(change).lastScheduledRun
        }
        pendingSave = write
        let recorded = await write.value
        current.lastScheduledRun = ScanSchedule.laterRun(current.lastScheduledRun, recorded, now: now())
    }

    // MARK: - Text

    /// The selectable days, 1 (Sunday) ... 7, named for the locale; a name is empty only if the calendar has none.
    func weekdayOptions(locale: Locale = .current) -> [WeekdayOption] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = locale
        return (1 ... 7).map { WeekdayOption(value: $0, name: ScanSchedule.weekdayName($0, calendar: calendar)) }
    }

    func timeDate(calendar: Calendar = .current) -> Date {
        calendar.date(from: DateComponents(hour: hour, minute: minute)) ?? Date(timeIntervalSinceReferenceDate: 0)
    }

    /// "Weekly, Sunday 02:00: a quick scan. It runs only while ..."; the day and time come from
    /// `ScanSchedule.description`, whose clock follows the locale (12 h or 24 h).
    func scheduleSummary(locale: Locale = .current, timeZone: TimeZone = .current) -> String {
        guard current.weeklyScanEnabled else { return SettingsText.weeklyScanOff }
        let keepsRunning = switch loginStatus {
        case .enabled: SettingsText.runsWhileOpenAtLogin
        case .requiresApproval: SettingsText.runsOnceApproved
        case .disabled, .unavailable: SettingsText.runsWhileOpen
        }
        let when = current.schedule.description(locale: locale, timeZone: timeZone)
        return "\(when): a quick scan. \(keepsRunning) \(SettingsText.missedRun)"
    }
}
