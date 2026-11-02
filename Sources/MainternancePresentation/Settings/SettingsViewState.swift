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
    static let problemAlertsHint = "A notification when a scan finds files to review"
    static let weeklyDigest = "Weekly digest"
    static let weeklyDigestHint = "A notification with the result of each weekly scan"
    static let weeklyScanOff = "The weekly quick scan is off."
    static let runsWhileOpen = "Runs only while Mainternance is open; turn on Launch at login to keep it running."
    static let runsWhileOpenAtLogin = "Runs only while Mainternance is open; it opens at login."
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
/// Saves run one after another in the order the changes were made, so the last change is the one on disk. A save
/// keeps the newer of the two `lastScheduledRun` values (the scheduler records its runs in the same file), so a
/// Settings change can never erase that record and make the weekly scan run twice in one week.
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

    /// The toggle shows the real login-item state: on only when macOS has it enabled.
    var launchAtLogin: Bool {
        loginStatus == .enabled
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
        notificationAuthorization = await notifications.authorization()
        current = loaded
        current.launchAtLogin = launchAtLogin
        onChange?(current)
    }

    /// Re-reads what macOS reports (the owner may have changed it in System Settings). Writes nothing.
    public func refreshStatus() async {
        loginStatus = loginItem.status()
        current.launchAtLogin = launchAtLogin
        notificationAuthorization = await notifications.authorization()
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
        current.launchAtLogin = launchAtLogin
        await commit()
    }

    /// Turning it on marks the current week as done, so the first scheduled scan runs at the next scheduled time
    /// rather than at once for a time that already passed.
    public func setWeeklyScanEnabled(_ enabled: Bool) async {
        if enabled, !current.weeklyScanEnabled {
            current.lastScheduledRun = Self.later(current.lastScheduledRun, now())
        }
        current.weeklyScanEnabled = enabled
        await commit()
    }

    public func setWeekday(_ value: Int) async {
        current.schedule.weekday = ScheduleInput.weekday(value)
        await commit()
    }

    public func setTime(hour: Int, minute: Int) async {
        current.schedule.hour = ScheduleInput.hour(hour)
        current.schedule.minute = ScheduleInput.minute(minute)
        await commit()
    }

    func setTime(from date: Date, calendar: Calendar = .current) async {
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        await setTime(hour: parts.hour ?? hour, minute: parts.minute ?? minute)
    }

    public func setProblemAlerts(_ enabled: Bool) async {
        current.problemAlerts = enabled
        if enabled {
            await askForPermissionIfUndecided()
        }
        await commit()
    }

    public func setWeeklyDigest(_ enabled: Bool) async {
        current.weeklyDigest = enabled
        if enabled {
            await askForPermissionIfUndecided()
        }
        await commit()
    }

    /// macOS shows its prompt only while undecided; it is asked at most once per launch.
    private func askForPermissionIfUndecided() async {
        notificationAuthorization = await notifications.authorization()
        guard notificationAuthorization == .notDetermined, !askedForPermission else { return }
        askedForPermission = true
        notificationAuthorization = await notifications.requestAuthorization()
    }

    /// Reports the change at once (the scheduler must hold the new values before anything is written), then saves
    /// `current` after every earlier save finished, keeping the newer `lastScheduledRun`.
    private func commit() async {
        onChange?(current)
        let snapshot = current
        let previous = pendingSave
        let store = preferences
        let save = Task<Date?, Never> {
            await previous?.value
            var merged = snapshot
            merged.lastScheduledRun = await Self.later(snapshot.lastScheduledRun, store.load().lastScheduledRun)
            await store.save(merged)
            return merged.lastScheduledRun
        }
        pendingSave = save
        let lastRun = await save.value
        current.lastScheduledRun = Self.later(current.lastScheduledRun, lastRun)
    }

    private nonisolated static func later(_ first: Date?, _ second: Date?) -> Date? {
        switch (first, second) {
        case let (first?, second?): max(first, second)
        case let (first?, nil): first
        case let (nil, second): second
        }
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

    /// "Weekly quick scan, Sunday 02:00. Runs only while ..."; the clock follows the locale (12 h or 24 h).
    func scheduleSummary(locale: Locale = .current, timeZone: TimeZone = .current) -> String {
        guard current.weeklyScanEnabled else { return SettingsText.weeklyScanOff }
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = locale
        calendar.timeZone = timeZone
        let day = ScanSchedule.weekdayName(weekday, calendar: calendar)
        let time = calendar.date(from: DateComponents(hour: hour, minute: minute))
            .map {
                $0.formatted(Date.FormatStyle(locale: locale, calendar: calendar, timeZone: timeZone).hour().minute())
            } ?? ""
        let keepsRunning = launchAtLogin ? SettingsText.runsWhileOpenAtLogin : SettingsText.runsWhileOpen
        return "Weekly quick scan, \(day) \(time). \(keepsRunning)"
    }
}
