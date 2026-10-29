import MainternanceDomain
import SwiftUI

public struct PopoverView: View {
    private let viewModel: OverviewViewModel
    private let openWindow: () -> Void
    private let scanNow: () -> Void

    public init(viewModel: OverviewViewModel, openWindow: @escaping () -> Void, scanNow: @escaping () -> Void) {
        self.viewModel = viewModel
        self.openWindow = openWindow
        self.scanNow = scanNow
    }

    public var body: some View {
        GlassPanel {
            VStack(alignment: .leading, spacing: 12) {
                if let overview = viewModel.overview {
                    content(overview)
                } else {
                    ProgressView().frame(maxWidth: .infinity, minHeight: 120)
                }
            }
            .padding(16)
        }
        .frame(width: 320)
        .onAppear { viewModel.setVisible(true) }
        .onDisappear { viewModel.setVisible(false) }
    }

    @ViewBuilder
    private func content(_ overview: Overview) -> some View {
        let state = overview.report.overall
        let snapshot = overview.snapshot
        hero(state: state, count: overview.report.attentionChecks.count)
        Divider()
        HStack(alignment: .top) {
            MetricColumn(title: "CPU", symbol: "cpu", value: percent(snapshot.cpuUsage), state: .good)
            MetricColumn(
                title: "Memory", symbol: "memorychip",
                value: memoryName(snapshot.memoryPressure), state: memoryState(snapshot.memoryPressure)
            )
            MetricColumn(
                title: "Thermal", symbol: "thermometer.medium",
                value: thermalValue(snapshot), state: thermalState(snapshot.thermal)
            )
            if let battery = snapshot.battery {
                MetricColumn(
                    title: "Battery", symbol: batterySymbol(battery),
                    value: "\(battery.percent)%", state: battery.percent <= 10 && !battery.isCharging ? .problem : .good
                )
            }
        }
        Divider()
        VStack(spacing: 8) {
            InfoRow(
                title: "Disk free", value: bytes(snapshot.diskFreeBytes), symbol: "internaldrive",
                state: check(overview, .diskSpace)
            )
            if let health = snapshot.battery?.healthPercent {
                InfoRow(
                    title: "Battery health", value: "\(health)%", symbol: "battery.100percent",
                    state: check(overview, .batteryHealth)
                )
            }
            InfoRow(title: "Last scan", value: lastScanText(overview.scan.lastScan), symbol: "clock")
            InfoRow(title: "Next scan", value: nextScanText(overview.scan.nextScan), symbol: "calendar")
        }
        Divider()
        actionButton("Scan now", symbol: "arrow.clockwise", action: scanNow)
        actionButton("Open Mainternance", symbol: "chevron.right", action: openWindow)
    }

    private func hero(state: HealthState, count: Int) -> some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text("This Mac").font(.caption).foregroundStyle(.secondary)
                Text(state.title).font(.system(size: 24, weight: .semibold)).foregroundStyle(state.color)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Image(systemName: state == .good ? "checkmark.shield" : "exclamationmark.shield")
                    .font(.system(size: 24))
                    .foregroundStyle(state.color)
                if state != .good {
                    Text(count == 1 ? "1 check" : "\(count) checks")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func actionButton(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(title)
                Spacer()
                Image(systemName: symbol).foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .font(.system(size: 13))
    }

    // MARK: Display formatting

    private func check(_ overview: Overview, _ id: CheckID) -> HealthState {
        overview.report.checks.first { $0.id == id }?.state ?? .good
    }

    private func percent(_ fraction: Double) -> String {
        "\(Int((fraction * 100).rounded()))%"
    }

    private func memoryName(_ pressure: MemoryPressure) -> String {
        switch pressure {
        case .normal: "Green"
        case .warning: "Amber"
        case .critical: "Red"
        }
    }

    private func memoryState(_ pressure: MemoryPressure) -> HealthState {
        switch pressure {
        case .normal: .good
        case .warning: .needsAttention
        case .critical: .problem
        }
    }

    private func thermalState(_ level: ThermalLevel) -> HealthState {
        switch level {
        case .nominal, .fair: .good
        case .serious: .needsAttention
        case .critical: .problem
        }
    }

    private func thermalValue(_ snapshot: SystemSnapshot) -> String {
        if let celsius = snapshot.temperatureCelsius {
            return "\(Int(celsius.rounded()))°"
        }
        switch snapshot.thermal {
        case .nominal: return "Normal"
        case .fair: return "Fair"
        case .serious: return "Hot"
        case .critical: return "Critical"
        }
    }

    private func batterySymbol(_ battery: BatterySnapshot) -> String {
        if battery.isCharging {
            return "battery.100percent.bolt"
        }
        switch battery.percent {
        case ..<13: return "battery.0percent"
        case ..<38: return "battery.25percent"
        case ..<63: return "battery.50percent"
        case ..<88: return "battery.75percent"
        default: return "battery.100percent"
        }
    }

    private func bytes(_ value: Int64) -> String {
        value.formatted(.byteCount(style: .file, allowedUnits: .all, spellsOutZero: false))
    }

    private func lastScanText(_ date: Date?) -> String {
        guard let date else { return "Never" }
        return date.formatted(.relative(presentation: .named))
    }

    private func nextScanText(_ date: Date?) -> String {
        guard let date else { return "Not scheduled" }
        return date.formatted(.relative(presentation: .named))
    }
}
