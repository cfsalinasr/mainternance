import Foundation
import MainternanceDomain
import Observation

/// The source of truth for the weekly scan schedule that `SettingsViewState` edits. It is a preview: nothing runs
/// on it yet, and the Scanner screen does not show it.
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

    /// Shown under the schedule controls in Settings.
    static let previewCaption = "Preview: nothing is scheduled yet"

    /// VoiceOver text for the schedule line; identifies it as a sample, not an active schedule.
    func accessibilityLabel(locale: Locale = .current, timeZone: TimeZone = .current) -> String {
        "Sample schedule: \(summary(locale: locale, timeZone: timeZone))"
    }

    func summary(locale: Locale = .current, timeZone: TimeZone = .current) -> String {
        schedule.description(locale: locale, timeZone: timeZone)
    }
}
