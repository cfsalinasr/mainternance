import Foundation

/// The weekly schedule the Settings screen edits (a preview: nothing runs on it yet).
struct ScanSchedule: Equatable {
    /// 1 = Sunday, matching `Calendar`.
    var weekday = 1
    var hour = 2
    var minute = 0

    /// The calendar's name for a weekday (1 = Sunday); empty when out of range.
    static func weekdayName(_ weekday: Int, calendar: Calendar) -> String {
        let names = calendar.weekdaySymbols
        return names.indices.contains(weekday - 1) ? names[weekday - 1] : ""
    }

    /// "Weekly, Sunday 02:00"; the clock follows the locale (12 h or 24 h).
    func description(locale: Locale = .current, timeZone: TimeZone = .current) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = locale
        calendar.timeZone = timeZone
        let day = Self.weekdayName(weekday, calendar: calendar)
        let time = calendar.date(from: DateComponents(hour: hour, minute: minute))
            .map {
                $0.formatted(Date.FormatStyle(locale: locale, calendar: calendar, timeZone: timeZone).hour().minute())
            } ?? ""
        return "Weekly, \(day) \(time)"
    }
}
