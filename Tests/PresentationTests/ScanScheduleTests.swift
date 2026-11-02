import Foundation
@testable import MainternancePresentation
import Testing

struct ScanScheduleTests {
    @Test func scheduleFollowsLocaleClock() throws {
        let utc = try #require(TimeZone(identifier: "UTC"))
        let schedule = ScanSchedule()
        #expect(schedule.description(locale: Locale(identifier: "en_GB"), timeZone: utc) == "Weekly, Sunday 02:00")
        #expect(schedule.description(locale: Locale(identifier: "en_US"), timeZone: utc).contains("2:00"))
        #expect(ScanSchedule(weekday: 99).description(locale: Locale(identifier: "en_GB"), timeZone: utc)
            .hasPrefix("Weekly,"))
    }
}
