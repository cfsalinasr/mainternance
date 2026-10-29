import SwiftUI

public struct SettingsView: View {
    /// Matches `SamplingPolicy`: 2 s visible, 45 s hidden, doubled in Low Power Mode.
    static let refreshNote = [
        "Metrics refresh every 2 s while this window or the menu bar popover is open,",
        "and about every 45 s otherwise; both intervals double in Low Power Mode."
    ].joined(separator: " ")

    private let state: SettingsViewState

    public init(state: SettingsViewState) {
        self.state = state
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Settings").font(.title2.bold())
                // At the top so it covers every control below, not only the notification toggles.
                Text(SampleDataCopy.settingsNote).font(.system(size: 12)).foregroundStyle(.secondary)
                general
                schedule
                notifications
                Text(Self.refreshNote)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .padding(20)
        }
    }

    private var general: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Launch at login", isOn: Binding(get: { state.launchAtLogin }, set: { state.launchAtLogin = $0 }))
                .accessibilityHint("Saved in this preview only")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .solidCard()
    }

    private var schedule: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Scan schedule").font(.headline)
            Picker("Day", selection: Binding(get: { state.weekday }, set: { state.setWeekday($0) })) {
                ForEach(state.weekdayOptions()) { Text($0.name).tag($0.value) }
            }
            .accessibilityLabel("Scan day")
            DatePicker(
                "Time",
                selection: Binding(get: { state.timeDate() }, set: { state.setTime(from: $0) }),
                displayedComponents: .hourAndMinute
            )
            .accessibilityLabel("Scan time")
            Text(state.scheduleSummary()).font(.system(size: 12)).foregroundStyle(.secondary)
                .accessibilityLabel(state.scheduleAccessibilityLabel())
            Text(ScanScheduleStore.previewCaption).font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .solidCard()
    }

    private var notifications: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Notifications").font(.headline)
            Toggle("Problem alerts", isOn: Binding(get: { state.problemAlerts }, set: { state.problemAlerts = $0 }))
                .accessibilityHint("Saved in this preview only")
            Toggle("Weekly digest", isOn: Binding(get: { state.weeklyDigest }, set: { state.weeklyDigest = $0 }))
                .accessibilityHint("Saved in this preview only")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .solidCard()
    }
}
