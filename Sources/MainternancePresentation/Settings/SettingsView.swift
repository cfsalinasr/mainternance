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
                general
                schedule
                notifications
                ForEach(state.notes, id: \.self) { note in
                    Text(note).font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Text(Self.refreshNote)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .padding(20)
        }
        // macOS may have changed (System Settings) while the window was closed.
        .task { await state.refreshStatus() }
    }

    private var general: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(SettingsText.launchAtLogin, isOn: Binding(
                get: { state.launchAtLogin },
                set: { value in Task { await state.setLaunchAtLogin(value) } }
            ))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .solidCard()
    }

    private var schedule: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Scan schedule").font(.headline)
            Toggle(SettingsText.weeklyScanToggle, isOn: Binding(
                get: { state.current.weeklyScanEnabled },
                set: { value in Task { await state.setWeeklyScanEnabled(value) } }
            ))
            Picker("Day", selection: Binding(
                get: { state.weekday },
                set: { value in Task { await state.setWeekday(value) } }
            )) {
                ForEach(state.weekdayOptions()) { Text($0.name).tag($0.value) }
            }
            .accessibilityLabel("Scan day")
            .disabled(!state.scheduleControlsEnabled)
            DatePicker(
                "Time",
                selection: Binding(
                    get: { state.timeDate() },
                    set: { value in Task { await state.setTime(from: value) } }
                ),
                displayedComponents: .hourAndMinute
            )
            .accessibilityLabel("Scan time")
            .disabled(!state.scheduleControlsEnabled)
            Text(state.scheduleSummary()).font(.system(size: 12)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .solidCard()
    }

    private var notifications: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Notifications").font(.headline)
            Toggle(SettingsText.problemAlerts, isOn: Binding(
                get: { state.current.problemAlerts },
                set: { value in Task { await state.setProblemAlerts(value) } }
            ))
            .accessibilityHint(SettingsText.problemAlertsHint)
            Toggle(SettingsText.weeklyDigest, isOn: Binding(
                get: { state.current.weeklyDigest },
                set: { value in Task { await state.setWeeklyDigest(value) } }
            ))
            .accessibilityHint(SettingsText.weeklyDigestHint)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .solidCard()
    }
}
