import Foundation
import Observation

/// The one source of truth for the weekly scan schedule. `SettingsViewState` edits it and
/// `ScannerViewState` reads it, so both screens always show the same schedule.
@MainActor
@Observable
public final class ScanScheduleStore {
    private(set) var schedule: ScanSchedule

    public init() {
        schedule = ScanSchedule()
    }

    func setWeekday(_ value: Int) {
        schedule.weekday = ScheduleInput.weekday(value)
    }

    func setTime(hour: Int, minute: Int) {
        schedule.hour = ScheduleInput.hour(hour)
        schedule.minute = ScheduleInput.minute(minute)
    }

    /// Shown under the schedule controls and next to the Scanner's schedule line.
    static let previewCaption = "Preview: nothing is scheduled yet"

    /// VoiceOver text for the schedule line; identifies it as a sample, not an active schedule.
    func accessibilityLabel(locale: Locale = .current, timeZone: TimeZone = .current) -> String {
        "Sample schedule: \(summary(locale: locale, timeZone: timeZone))"
    }

    func summary(locale: Locale = .current, timeZone: TimeZone = .current) -> String {
        schedule.description(locale: locale, timeZone: timeZone)
    }
}
