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

struct WeekdayOption: Equatable, Identifiable {
    let value: Int
    let name: String

    var id: Int {
        value
    }
}

@MainActor
@Observable
public final class SettingsViewState {
    var launchAtLogin = false
    var problemAlerts = true
    var weeklyDigest = true
    private let scheduleStore: ScanScheduleStore

    var weekday: Int {
        scheduleStore.schedule.weekday
    }

    var hour: Int {
        scheduleStore.schedule.hour
    }

    var minute: Int {
        scheduleStore.schedule.minute
    }

    public init(schedule: ScanScheduleStore = ScanScheduleStore()) {
        scheduleStore = schedule
    }

    /// The selectable days, 1 (Sunday) ... 7, named for the locale; a name is empty only if the calendar has none.
    func weekdayOptions(locale: Locale = .current) -> [WeekdayOption] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = locale
        return (1 ... 7).map { WeekdayOption(value: $0, name: ScanSchedule.weekdayName($0, calendar: calendar)) }
    }

    func setWeekday(_ value: Int) {
        scheduleStore.setWeekday(value)
    }

    func setTime(hour: Int, minute: Int) {
        scheduleStore.setTime(hour: hour, minute: minute)
    }

    func setTime(from date: Date, calendar: Calendar = .current) {
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        setTime(hour: parts.hour ?? hour, minute: parts.minute ?? minute)
    }

    func timeDate(calendar: Calendar = .current) -> Date {
        calendar.date(from: DateComponents(hour: hour, minute: minute)) ?? Date(timeIntervalSinceReferenceDate: 0)
    }

    func scheduleSummary(locale: Locale = .current, timeZone: TimeZone = .current) -> String {
        scheduleStore.summary(locale: locale, timeZone: timeZone)
    }
}
