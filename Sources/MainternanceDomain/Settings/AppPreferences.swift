import Foundation

/// The weekly scan time. Each week has one slot: the most recent moment that matches the weekday, hour and minute.
public struct ScanSchedule: Equatable, Codable, Sendable {
    /// 1 = Sunday ... 7 = Saturday, matching `Calendar`.
    public var weekday: Int
    public var hour: Int
    public var minute: Int

    public init(weekday: Int = 1, hour: Int = 2, minute: Int = 0) {
        self.weekday = weekday
        self.hour = hour
        self.minute = minute
    }

    private enum CodingKeys: String, CodingKey {
        case weekday, hour, minute
    }

    /// A missing field takes its default; a field of the wrong type still fails.
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = ScanSchedule()
        weekday = try values.decodeIfPresent(Int.self, forKey: .weekday) ?? fallback.weekday
        hour = try values.decodeIfPresent(Int.self, forKey: .hour) ?? fallback.hour
        minute = try values.decodeIfPresent(Int.self, forKey: .minute) ?? fallback.minute
    }

    /// The same schedule with every field pulled into range (a hand-edited file may hold anything).
    public func clamped() -> ScanSchedule {
        ScanSchedule(weekday: min(max(weekday, 1), 7), hour: min(max(hour, 0), 23), minute: min(max(minute, 0), 59))
    }

    /// The start of the week-slot that contains `now`: the latest matching moment at or before `now`. A time that
    /// does not exist on a daylight-saving day resolves to the next real time; a time that happens twice resolves
    /// to its first occurrence, so one slot never has two starts.
    public func slotStart(containing now: Date, calendar: Calendar) -> Date {
        let safe = clamped()
        let parts = DateComponents(hour: safe.hour, minute: safe.minute, weekday: safe.weekday)
        // `nextDate(after:)` is exclusive, so search from just past `now` to include an exact match, then step
        // back once more if that lands after `now` (a fractional `now` just before the slot).
        var from = now.addingTimeInterval(1)
        for _ in 0 ..< 2 {
            guard let found = calendar.nextDate(
                after: from, matching: parts, matchingPolicy: .nextTime, repeatedTimePolicy: .first,
                direction: .backward
            ) else { break }
            if found <= now {
                return Self.firstOccurrence(of: found, matching: parts, calendar: calendar)
            }
            from = found
        }
        // No match (should not happen with clamped values): a start in the distant past makes the scan due at
        // most once and never again in a loop.
        return .distantPast
    }

    /// A backward search can land on the second of two identical wall-clock times (the hour repeated when clocks
    /// fall back); a forward search from the start of that day finds the first one.
    private static func firstOccurrence(of found: Date, matching parts: DateComponents, calendar: Calendar) -> Date {
        let dayStart = calendar.startOfDay(for: found)
        guard let first = calendar.nextDate(
            after: dayStart.addingTimeInterval(-1), matching: parts, matchingPolicy: .nextTime,
            repeatedTimePolicy: .first, direction: .forward
        ), first <= found else { return found }
        return first
    }

    /// True when the slot containing `now` has started and has not run yet. A missing `lastRun` counts as not run.
    /// A `lastRun` up to a week in the future (the clock moved back) keeps the slot as done; one further ahead
    /// cannot be real and counts as not run (see `validLastRun`).
    public func isDue(now: Date, lastRun: Date?, calendar: Calendar) -> Bool {
        let start = slotStart(containing: now, calendar: calendar)
        guard now >= start else { return false }
        guard let lastRun = Self.validLastRun(lastRun, now: now) else { return true }
        return lastRun < start
    }

    /// When the weekly scan runs next: `now` when the current slot is due (it runs at the next check), otherwise
    /// the start of the first later slot that `lastRun` does not already cover. Nil only when the calendar finds no
    /// matching moment (not expected with clamped values).
    public func nextRun(now: Date, lastRun: Date?, calendar: Calendar) -> Date? {
        if isDue(now: now, lastRun: lastRun, calendar: calendar) {
            return now
        }
        let safe = clamped()
        let parts = DateComponents(hour: safe.hour, minute: safe.minute, weekday: safe.weekday)
        var from = now
        // A valid recorded run is at most a week ahead, so it can cover one later slot at most.
        for _ in 0 ..< 3 {
            guard let found = calendar.nextDate(
                after: from, matching: parts, matchingPolicy: .nextTime, repeatedTimePolicy: .first,
                direction: .forward
            ) else { return nil }
            if isDue(now: found, lastRun: lastRun, calendar: calendar) {
                return found
            }
            from = found
        }
        return nil
    }

    /// How far ahead of `now` a recorded run may be and still count: one week.
    public static let futureRunLimit: TimeInterval = 7 * 24 * 60 * 60

    /// `run`, or nil when it is more than `futureRunLimit` after `now` (a clock set far ahead, a hand-edited file):
    /// such a value would otherwise block the weekly scan for as long as it stays in the future.
    public static func validLastRun(_ run: Date?, now: Date) -> Date? {
        guard let run, run.timeIntervalSince(now) <= futureRunLimit else { return nil }
        return run
    }

    /// The later of two recorded runs, ignoring any that `validLastRun` rejects.
    public static func laterRun(_ first: Date?, _ second: Date?, now: Date) -> Date? {
        switch (validLastRun(first, now: now), validLastRun(second, now: now)) {
        case let (first?, second?): max(first, second)
        case let (first?, nil): first
        case let (nil, second): second
        }
    }

    /// The calendar's name for a weekday (1 = Sunday); empty when out of range.
    public static func weekdayName(_ weekday: Int, calendar: Calendar) -> String {
        let names = calendar.weekdaySymbols
        return names.indices.contains(weekday - 1) ? names[weekday - 1] : ""
    }

    /// "Weekly, Sunday 02:00"; the clock follows the locale (12 h or 24 h).
    public func description(locale: Locale = .current, timeZone: TimeZone = .current) -> String {
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

/// Everything the Settings screen saves.
public struct AppPreferences: Equatable, Codable, Sendable {
    public var launchAtLogin: Bool
    public var weeklyScanEnabled: Bool
    public var schedule: ScanSchedule
    /// Notify when a finished scan has findings.
    public var problemAlerts: Bool
    /// Notify with the result of each scheduled scan.
    public var weeklyDigest: Bool
    /// When the scheduler last started a scheduled scan; nil when it never has.
    public var lastScheduledRun: Date?

    public init(
        launchAtLogin: Bool, weeklyScanEnabled: Bool, schedule: ScanSchedule, problemAlerts: Bool,
        weeklyDigest: Bool, lastScheduledRun: Date?
    ) {
        self.launchAtLogin = launchAtLogin
        self.weeklyScanEnabled = weeklyScanEnabled
        self.schedule = schedule
        self.problemAlerts = problemAlerts
        self.weeklyDigest = weeklyDigest
        self.lastScheduledRun = lastScheduledRun
    }

    public static let defaults = AppPreferences(
        launchAtLogin: false, weeklyScanEnabled: false, schedule: ScanSchedule(), problemAlerts: true,
        weeklyDigest: true, lastScheduledRun: nil
    )

    private enum CodingKeys: String, CodingKey {
        case launchAtLogin, weeklyScanEnabled, schedule, problemAlerts, weeklyDigest, lastScheduledRun
    }

    /// The read-modify-write rule every preferences store follows: applies `change` to these values, then keeps the
    /// later valid `lastScheduledRun` of before and after, so no change can move a recorded run back (which could
    /// run the weekly scan twice in one week).
    public func updated(now: Date, _ change: (inout AppPreferences) -> Void) -> AppPreferences {
        var next = self
        change(&next)
        next.lastScheduledRun = ScanSchedule.laterRun(lastScheduledRun, next.lastScheduledRun, now: now)
        return next
    }

    /// A missing field takes its default, so a file written before a field existed keeps every other choice. A
    /// field of the wrong type, or text that is not a JSON object, still fails (the file is damaged).
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = Self.defaults
        launchAtLogin = try values.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? fallback.launchAtLogin
        weeklyScanEnabled = try values.decodeIfPresent(Bool.self, forKey: .weeklyScanEnabled)
            ?? fallback.weeklyScanEnabled
        schedule = try values.decodeIfPresent(ScanSchedule.self, forKey: .schedule) ?? fallback.schedule
        problemAlerts = try values.decodeIfPresent(Bool.self, forKey: .problemAlerts) ?? fallback.problemAlerts
        weeklyDigest = try values.decodeIfPresent(Bool.self, forKey: .weeklyDigest) ?? fallback.weeklyDigest
        lastScheduledRun = try values.decodeIfPresent(Date.self, forKey: .lastScheduledRun)
    }
}
