import Foundation
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

@MainActor
@Observable
public final class SettingsViewState {
    var launchAtLogin = false
    var problemAlerts = true
    var weeklyDigest = true
    private(set) var weekday: Int
    private(set) var hour: Int
    private(set) var minute: Int

    public init() {
        let schedule = ScannerSampleData.schedule
        weekday = ScheduleInput.weekday(schedule.weekday)
        hour = ScheduleInput.hour(schedule.hour)
        minute = ScheduleInput.minute(schedule.minute)
    }

    func setWeekday(_ value: Int) {
        weekday = ScheduleInput.weekday(value)
    }

    func setTime(hour: Int, minute: Int) {
        self.hour = ScheduleInput.hour(hour)
        self.minute = ScheduleInput.minute(minute)
    }

    func setTime(from date: Date, calendar: Calendar = .current) {
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        setTime(hour: parts.hour ?? hour, minute: parts.minute ?? minute)
    }

    func timeDate(calendar: Calendar = .current) -> Date {
        calendar.date(from: DateComponents(hour: hour, minute: minute)) ?? Date(timeIntervalSinceReferenceDate: 0)
    }

    func scheduleSummary(locale: Locale = .current, timeZone: TimeZone = .current) -> String {
        ScanSchedule(weekday: weekday, hour: hour, minute: minute).description(locale: locale, timeZone: timeZone)
    }
}
