import Foundation
import MainternanceDomain
import Testing

/// When the weekly scan runs next, as Home and the popover show it.
struct ScanScheduleNextRunTests {
    private let sunday = ScanSchedule(weekday: 1, hour: 2, minute: 0)

    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        return calendar
    }

    private func date(_ text: String) throws -> Date {
        let numbers = text.split(whereSeparator: { $0 == "-" || $0 == " " || $0 == ":" }).compactMap { Int($0) }
        try #require(numbers.count == 5)
        return try #require(utc.date(from: DateComponents(
            year: numbers[0], month: numbers[1], day: numbers[2], hour: numbers[3], minute: numbers[4]
        )))
    }

    @Test func afterThisWeeksRunTheNextIsNextWeeksSlot() throws {
        let now = try date("2026-11-04 10:00")
        let next = try sunday.nextRun(now: now, lastRun: date("2026-11-01 02:00"), calendar: utc)
        #expect(try next == date("2026-11-08 02:00"))
    }

    @Test func beforeTheSlotTheNextIsThisWeeksSlot() throws {
        let now = try date("2026-11-01 01:00")
        let next = try sunday.nextRun(now: now, lastRun: date("2026-10-25 02:00"), calendar: utc)
        #expect(try next == date("2026-11-01 02:00"))
    }

    /// A slot that started and has not run yet runs at the next check, so it is "now", never a week away.
    @Test func aDueSlotIsNow() throws {
        let now = try date("2026-11-04 10:00")
        #expect(sunday.nextRun(now: now, lastRun: nil, calendar: utc) == now)
        #expect(try sunday.nextRun(now: now, lastRun: date("2026-10-25 02:00"), calendar: utc) == now)
    }

    /// The clock moved back: the next slot is still covered by the recorded run, so the one after it is next.
    @Test func aSlotTheRecordedRunCoversIsSkipped() throws {
        let now = try date("2026-11-07 10:00")
        let next = try sunday.nextRun(now: now, lastRun: date("2026-11-08 05:00"), calendar: utc)
        #expect(try next == date("2026-11-15 02:00"))
    }
}
