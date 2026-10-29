import Foundation
import MainternanceDomain

/// Display-ready popover content derived from an `Overview`. All state comes from the domain report.
public struct PopoverModel: Equatable, Sendable {
    public struct Hero: Equatable, Sendable {
        public var state: HealthState
        public var title: String
        public var symbol: String
        public var checkCount: Int
        /// Nil when the state is good (the count is hidden).
        public var checksText: String?
    }

    public struct Metric: Equatable, Sendable, Identifiable {
        public var id: String {
            title
        }

        public var title: String
        public var symbol: String
        public var value: String
        public var state: HealthState
    }

    public struct Row: Equatable, Sendable, Identifiable {
        public var id: String {
            title
        }

        public var title: String
        public var value: String
        public var symbol: String
        public var state: HealthState
    }

    public var hero: Hero
    public var metrics: [Metric]
    public var rows: [Row]

    public init(overview: Overview, now: Date = Date(), locale: Locale = .current) {
        let snapshot = overview.snapshot
        let report = overview.report
        let state = report.overall
        let count = report.attentionChecks.count

        hero = Hero(
            state: state, title: state.title,
            symbol: state == .good ? "checkmark.shield" : "exclamationmark.shield",
            checkCount: count,
            checksText: Self.checksText(state: state, count: count)
        )

        metrics = Self.makeMetrics(snapshot: snapshot, report: report)
        rows = Self.makeRows(overview: overview, now: now, locale: locale)
    }

    /// Nil when the state is good (the count is hidden).
    private static func checksText(state: HealthState, count: Int) -> String? {
        if state == .good {
            return nil
        }
        return count == 1 ? "1 check" : "\(count) checks"
    }

    private static func makeMetrics(snapshot: SystemSnapshot, report: HealthReport) -> [Metric] {
        func checkState(_ id: CheckID) -> HealthState? {
            report.checks.first { $0.id == id }?.state
        }

        var metrics = [
            // No CPU check exists yet, so CPU is always neutral.
            Metric(title: "CPU", symbol: "cpu", value: percent(snapshot.cpuUsage), state: .good)
        ]
        if let memory = checkState(.memoryPressure) {
            metrics.append(Metric(
                title: "Memory", symbol: "memorychip",
                value: memoryName(snapshot.memoryPressure), state: memory
            ))
        }
        if let thermal = checkState(.thermal) {
            metrics.append(Metric(
                title: "Thermal", symbol: "thermometer.medium",
                value: thermalName(snapshot.thermal), state: thermal
            ))
        }
        if let battery = snapshot.battery {
            metrics.append(Metric(
                title: "Battery", symbol: batterySymbol(battery),
                value: "\(battery.percent)%", state: checkState(.batteryHealth) ?? .good
            ))
        }
        return metrics
    }

    private static func makeRows(overview: Overview, now: Date, locale: Locale) -> [Row] {
        func checkState(_ id: CheckID) -> HealthState? {
            overview.report.checks.first { $0.id == id }?.state
        }

        var rows = [
            Row(
                title: "Disk free", value: formatBytes(overview.snapshot.diskFreeBytes), symbol: "internaldrive",
                state: checkState(.diskSpace) ?? .good
            )
        ]
        if let health = overview.snapshot.battery?.healthPercent {
            rows.append(Row(
                title: "Battery health", value: "\(health)%", symbol: "battery.100percent",
                state: checkState(.batteryHealth) ?? .good
            ))
        }
        rows.append(Row(
            title: "Last scan",
            value: overview.scan.lastScan.map { relative($0, now: now, locale: locale) } ?? "Never",
            symbol: "clock", state: .good
        ))
        rows.append(Row(
            title: "Next scan",
            value: overview.scan.nextScan.map { relative($0, now: now, locale: locale) } ?? "Not scheduled",
            symbol: "calendar", state: .good
        ))
        return rows
    }

    /// "3 days ago" / "in 2 days"; the one relative-date wording shared by the popover and Home.
    static func relative(_ date: Date, now: Date, locale: Locale) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = locale
        formatter.dateTimeStyle = .named
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: now)
    }

    /// A usage fraction as a whole percent, clamped to 0...100. A non-finite fraction (a first sample can
    /// divide zero by zero) shows as 0%, because `Int(_:)` would trap on it.
    private static func percent(_ fraction: Double) -> String {
        guard fraction.isFinite else { return "0%" }
        let clamped = min(max(fraction, 0), 1)
        return "\(Int((clamped * 100).rounded()))%"
    }

    static func memoryName(_ pressure: MemoryPressure) -> String {
        switch pressure {
        case .normal: "Green"
        case .warning: "Amber"
        case .critical: "Red"
        }
    }

    static func thermalName(_ level: ThermalLevel) -> String {
        switch level {
        case .nominal: "Nominal"
        case .fair: "Fair"
        case .serious: "Serious"
        case .critical: "Critical"
        }
    }

    private static func batterySymbol(_ battery: BatterySnapshot) -> String {
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
}
