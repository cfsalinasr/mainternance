import Foundation
import MainternanceDomain
import Testing

struct ScanScheduleTests {
    private func calendar(_ zone: String) throws -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: zone))
        return calendar
    }

    /// `text` is "yyyy-MM-dd HH:mm" in `calendar`'s time zone.
    private func date(_ calendar: Calendar, _ text: String) throws -> Date {
        let numbers = text.split(whereSeparator: { $0 == "-" || $0 == " " || $0 == ":" }).compactMap { Int($0) }
        try #require(numbers.count == 5)
        return try #require(calendar.date(from: DateComponents(
            year: numbers[0], month: numbers[1], day: numbers[2], hour: numbers[3], minute: numbers[4]
        )))
    }

    /// Sunday 02:00 (2026-11-01 is a Sunday).
    private let sunday = ScanSchedule(weekday: 1, hour: 2, minute: 0)

    @Test func slotStartMidweekIsThePreviousSunday() throws {
        let utc = try calendar("UTC")
        let wednesday = try date(utc, "2026-11-04 10:00")
        #expect(try sunday.slotStart(containing: wednesday, calendar: utc) == date(utc, "2026-11-01 02:00"))
    }

    @Test func slotStartJustBeforeTheSlotIsTheWeekBefore() throws {
        let utc = try calendar("UTC")
        let early = try date(utc, "2026-11-01 01:59")
        #expect(try sunday.slotStart(containing: early, calendar: utc) == date(utc, "2026-10-25 02:00"))
    }

    @Test func slotStartExactlyAtTheSlotIsThatInstant() throws {
        let utc = try calendar("UTC")
        let exact = try date(utc, "2026-11-01 02:00")
        #expect(sunday.slotStart(containing: exact, calendar: utc) == exact)
    }

    @Test func dueWhenNeverRunAndPastTheSlot() throws {
        let utc = try calendar("UTC")
        #expect(try sunday.isDue(now: date(utc, "2026-11-04 10:00"), lastRun: nil, calendar: utc))
    }

    @Test func dueExactlyAtTheSlot() throws {
        let utc = try calendar("UTC")
        #expect(try sunday.isDue(now: date(utc, "2026-11-01 02:00"), lastRun: nil, calendar: utc))
    }

    @Test func notDueWhenAlreadyRunInThisSlot() throws {
        let utc = try calendar("UTC")
        let now = try date(utc, "2026-11-04 10:00")
        #expect(try !sunday.isDue(now: now, lastRun: date(utc, "2026-11-01 02:00"), calendar: utc))
        #expect(try !sunday.isDue(now: now, lastRun: date(utc, "2026-11-03 09:00"), calendar: utc))
    }

    @Test func dueWhenLastRunWasThePreviousWeek() throws {
        let utc = try calendar("UTC")
        let now = try date(utc, "2026-11-04 10:00")
        #expect(try sunday.isDue(now: now, lastRun: date(utc, "2026-10-25 02:00"), calendar: utc))
        #expect(try sunday.isDue(now: now, lastRun: date(utc, "2026-10-18 02:00"), calendar: utc))
    }

    @Test func notDueBeforeTheSlotWhenThePreviousSlotRan() throws {
        let utc = try calendar("UTC")
        let early = try date(utc, "2026-11-01 01:59")
        #expect(try !sunday.isDue(now: early, lastRun: date(utc, "2026-10-25 02:00"), calendar: utc))
    }

    /// 2026-03-08 02:30 does not exist in New York (clocks jump from 02:00 to 03:00). The slot must still run,
    /// and only once.
    @Test func springForwardRunsExactlyOnce() throws {
        let newYork = try calendar("America/New_York")
        let schedule = ScanSchedule(weekday: 1, hour: 2, minute: 30)
        let three = try date(newYork, "2026-03-08 03:00")
        #expect(schedule.isDue(now: three, lastRun: nil, calendar: newYork))
        let later = (0 ... 7 * 24 * 4).map { three.addingTimeInterval(TimeInterval($0) * 900) }
        let dueAfterRun = later.filter { schedule.isDue(now: $0, lastRun: three, calendar: newYork) }
        // The next due moment is the following Sunday 02:30, a week later; nothing in between.
        let nextSlot = try date(newYork, "2026-03-15 02:30")
        #expect(dueAfterRun.allSatisfy { $0 >= nextSlot })
        #expect(!dueAfterRun.isEmpty)
    }

    /// 2026-11-01 01:30 happens twice in New York (clocks fall back from 02:00 to 01:00). One run per slot.
    @Test func fallBackRunsExactlyOnce() throws {
        let newYork = try calendar("America/New_York")
        let schedule = ScanSchedule(weekday: 1, hour: 1, minute: 30)
        let firstOccurrence = Date(timeIntervalSince1970: 1_793_511_000) // 2026-11-01 05:30 UTC = 01:30 EDT
        #expect(newYork.component(.hour, from: firstOccurrence) == 1)
        #expect(schedule.isDue(now: firstOccurrence, lastRun: nil, calendar: newYork))
        let later = (1 ... 6 * 24 * 4).map { firstOccurrence.addingTimeInterval(TimeInterval($0) * 900) }
        #expect(later.allSatisfy { !schedule.isDue(now: $0, lastRun: firstOccurrence, calendar: newYork) })
    }

    @Test func clampedPullsValuesIntoRange() {
        #expect(ScanSchedule(weekday: 99, hour: -5, minute: 75).clamped() == ScanSchedule(
            weekday: 7, hour: 0, minute: 59
        ))
        #expect(ScanSchedule(weekday: 0, hour: 30, minute: -1).clamped() == ScanSchedule(
            weekday: 1, hour: 23, minute: 0
        ))
        #expect(ScanSchedule(weekday: 3, hour: 14, minute: 15).clamped() == ScanSchedule(
            weekday: 3, hour: 14, minute: 15
        ))
    }

    @Test func scheduleFollowsLocaleClock() throws {
        let utc = try #require(TimeZone(identifier: "UTC"))
        let schedule = ScanSchedule()
        #expect(schedule.description(locale: Locale(identifier: "en_GB"), timeZone: utc) == "Weekly, Sunday 02:00")
        #expect(schedule.description(locale: Locale(identifier: "en_US"), timeZone: utc).contains("2:00"))
        #expect(ScanSchedule(weekday: 99).description(locale: Locale(identifier: "en_GB"), timeZone: utc)
            .hasPrefix("Weekly,"))
    }

    @Test func weekdayNameIsEmptyOutOfRange() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US")
        #expect(ScanSchedule.weekdayName(0, calendar: calendar).isEmpty)
        #expect(ScanSchedule.weekdayName(8, calendar: calendar).isEmpty)
        #expect(ScanSchedule.weekdayName(2, calendar: calendar) == "Monday")
    }
}

struct AppPreferencesTests {
    private func coder() -> (JSONEncoder, JSONDecoder) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return (encoder, decoder)
    }

    @Test func defaultsAreOffAndAlertsOn() {
        let defaults = AppPreferences.defaults
        #expect(!defaults.launchAtLogin)
        #expect(!defaults.weeklyScanEnabled)
        #expect(defaults.problemAlerts)
        #expect(defaults.weeklyDigest)
        #expect(defaults.lastScheduledRun == nil)
        #expect(defaults.schedule == ScanSchedule())
    }

    @Test func jsonFieldNamesArePinned() throws {
        let json = """
        {"lastScheduledRun":1800000000,"launchAtLogin":true,"problemAlerts":false,\
        "schedule":{"hour":14,"minute":30,"weekday":4},"weeklyDigest":false,"weeklyScanEnabled":true}
        """
        let (encoder, decoder) = coder()
        let decoded = try decoder.decode(AppPreferences.self, from: Data(json.utf8))
        var expected = AppPreferences.defaults
        expected.launchAtLogin = true
        expected.weeklyScanEnabled = true
        expected.schedule = ScanSchedule(weekday: 4, hour: 14, minute: 30)
        expected.problemAlerts = false
        expected.weeklyDigest = false
        expected.lastScheduledRun = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(decoded == expected)
        let encoded = try #require(String(bytes: encoder.encode(decoded), encoding: .utf8))
        #expect(encoded == json)
    }

    @Test func nilLastRunRoundTrips() throws {
        let (encoder, decoder) = coder()
        let data = try encoder.encode(AppPreferences.defaults)
        #expect(try decoder.decode(AppPreferences.self, from: data) == .defaults)
    }
}
