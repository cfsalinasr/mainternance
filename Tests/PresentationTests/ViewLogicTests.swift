import Foundation
import MainternanceDomain
@testable import MainternancePresentation
import Testing

/// Rules that used to sit in views and now live in testable state types.
@MainActor
struct ViewLogicTests {
    @Test func weekdayOptionsCoverOneToSevenWithNames() {
        let options = SettingsViewState().weekdayOptions(locale: Locale(identifier: "en_US"))
        #expect(options.map(\.value) == Array(1 ... 7))
        #expect(options.first?.name == "Sunday")
        #expect(options.last?.name == "Saturday")
        #expect(options.allSatisfy { !$0.name.isEmpty })
    }

    @Test func weekdayNameIsEmptyOutOfRange() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US")
        #expect(ScanSchedule.weekdayName(0, calendar: calendar).isEmpty)
        #expect(ScanSchedule.weekdayName(8, calendar: calendar).isEmpty)
        #expect(ScanSchedule.weekdayName(2, calendar: calendar) == "Monday")
    }

    @Test func leftoverDisplayNameIsTheLastPathComponent() {
        func name(_ path: String) -> String {
            Leftover(id: path, path: path, bytes: 0).displayName
        }
        #expect(name("~/Library/Logs/VideoEditor") == "VideoEditor")
        #expect(name("~/Library/Logs/VideoEditor/") == "VideoEditor")
        #expect(name("~/") == "~")
        #expect(name("/") == "/")
        #expect(name("").isEmpty)
    }
}

@MainActor
struct ScheduleLabelTests {
    @Test func scheduleIsLabelledAsASample() {
        let states = SettingsViewState()
        states.setWeekday(2)
        states.setTime(hour: 9, minute: 5)
        let british = Locale(identifier: "en_GB")
        let utc = TimeZone(identifier: "UTC") ?? .gmt
        let summary = states.scheduleSummary(locale: british, timeZone: utc)
        #expect(summary == "Weekly, Monday 09:05")
        #expect(states.scheduleAccessibilityLabel(locale: british, timeZone: utc) == "Sample schedule: \(summary)")
        #expect(ScanScheduleStore.previewCaption == "Preview: nothing is scheduled yet")
    }

    @Test func helpTextForTheInertScanButtonIsHonest() {
        #expect(ScannerHelp.scanFromScanner == "Start a scan from the Scanner screen")
    }
}
