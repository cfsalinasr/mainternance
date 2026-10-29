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

    func summary(locale: Locale = .current, timeZone: TimeZone = .current) -> String {
        schedule.description(locale: locale, timeZone: timeZone)
    }
}
