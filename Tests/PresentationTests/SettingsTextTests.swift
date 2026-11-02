import Foundation
import MainternanceDomain
@testable import MainternancePresentation
import Testing

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
            "Weekly, Sunday 02:00: a quick scan.",
            "It runs only while Mainternance is open; turn on Launch at login to keep it running.",
            "If the Mac is asleep or Mainternance is closed at that time, it runs the next time Mainternance runs."
        ].joined(separator: " "))
        await rig.state.setWeekday(2)
        await rig.state.setTime(hour: 14, minute: 5)
        await rig.state.setLaunchAtLogin(true)
        #expect(rig.state.scheduleSummary(locale: british, timeZone: utc) == [
            "Weekly, Monday 14:05: a quick scan.", "It runs only while Mainternance is open; it opens at login.",
            SettingsText.missedRun
        ].joined(separator: " "))
        let american = rig.state.scheduleSummary(locale: Locale(identifier: "en_US"), timeZone: utc)
        #expect(american.hasPrefix("Weekly, Monday 2:05"))
        #expect(american.contains("PM"))
        rig.login.configure { $0.status = .requiresApproval }
        await rig.state.refreshStatus()
        #expect(rig.state.scheduleSummary(locale: british, timeZone: utc).contains(SettingsText.runsOnceApproved))
    }

    /// The summary reuses the schedule's own wording rather than formatting the day and time again.
    @Test func scheduleSummaryUsesTheScheduleDescription() async throws {
        let utc = try #require(TimeZone(identifier: "UTC"))
        let locale = Locale(identifier: "fr_FR")
        let rig = SettingsRig()
        await rig.state.setWeeklyScanEnabled(true)
        await rig.state.setWeekday(4)
        let described = rig.state.current.schedule.description(locale: locale, timeZone: utc)
        let summary = rig.state.scheduleSummary(locale: locale, timeZone: utc)
        #expect(summary.hasPrefix("\(described): a quick scan. "))
    }

    @Test func notificationHintsSayWhenTheyArrive() {
        #expect(SettingsText.weeklyDigestHint == "A notification with the result when a weekly scan finishes")
        #expect(SettingsText.problemAlertsHint == "A notification when a scan finds something to review")
        #expect(SettingsText.allowNotifications == "Allow notifications to receive these")
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
