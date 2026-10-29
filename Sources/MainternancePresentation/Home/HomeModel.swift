import Foundation
import MainternanceDomain

/// Display-ready Home content derived from an `Overview`. State and reason text come from the domain report.
public struct HomeModel: Equatable, Sendable {
    public struct Reason: Equatable, Sendable, Identifiable {
        public var id: CheckID
        public var text: String
        public var destination: AppDestination
    }

    public struct Banner: Equatable, Sendable {
        public var state: HealthState
        public var title: String
        public var symbol: String
        /// The attention checks' reasons, each a deep link. Empty when everything is good.
        public var reasons: [Reason]
        public var goodText: String
    }

    public struct Tile: Equatable, Sendable, Identifiable {
        public var id: String {
            title
        }

        public var title: String
        public var symbol: String
        public var value: String
        public var caption: String?
        public var state: HealthState
        public var destination: AppDestination
    }

    public struct ScanSummary: Equatable, Sendable {
        public var symbol: String
        public var state: HealthState
        public var last: String
        public var next: String
    }

    public var banner: Banner
    public var tiles: [Tile]
    public var scan: ScanSummary
    public var actions: [SuggestedAction]
    /// Nil when the sensor is unavailable; the Details row is then omitted.
    public var temperatureText: String?

    public init(overview: Overview, now: Date = Date(), locale: Locale = .current) {
        let snapshot = overview.snapshot
        let report = overview.report
        let state = report.overall

        banner = Banner(
            state: state, title: state.title,
            symbol: state == .good ? "checkmark.shield" : "exclamationmark.shield",
            reasons: report.attentionChecks.map { Reason(id: $0.id, text: $0.reason, destination: $0.destination) },
            goodText: "All checks passed"
        )

        func check(_ id: CheckID) -> HealthCheck? {
            report.checks.first { $0.id == id }
        }

        var tiles = [
            Tile(
                title: "Disk free", symbol: "internaldrive", value: formatFreeSpace(snapshot.diskFreeBytes),
                caption: snapshot.diskTotalBytes > 0 ? "of \(formatFreeSpace(snapshot.diskTotalBytes))" : nil,
                state: check(.diskSpace)?.state ?? .good, destination: check(.diskSpace)?.destination ?? .home
            )
        ]
        if let memory = check(.memoryPressure) {
            tiles.append(Tile(
                title: "Memory", symbol: "memorychip", value: PopoverModel.memoryName(snapshot.memoryPressure),
                caption: "pressure", state: memory.state, destination: memory.destination
            ))
        }
        if let thermal = check(.thermal) {
            tiles.append(Tile(
                title: "Thermal", symbol: "thermometer.medium", value: PopoverModel.thermalName(snapshot.thermal),
                caption: thermal.reason, state: thermal.state, destination: thermal.destination
            ))
        }
        if let battery = snapshot.battery {
            let parts = [
                battery.healthPercent.map { "health \($0)%" },
                battery.cycleCount.map { "\($0) cycles" }
            ].compactMap(\.self)
            tiles.append(Tile(
                title: "Battery", symbol: "battery.100percent", value: "\(battery.percent)%",
                caption: parts.isEmpty ? nil : parts.joined(separator: " · "),
                state: check(.batteryHealth)?.state ?? .good,
                destination: check(.batteryHealth)?.destination ?? .home
            ))
        }
        self.tiles = tiles

        let scanState = max(check(.lastScan)?.state ?? .good, check(.scannerFindings)?.state ?? .good)
        let findings = overview.scan.unresolvedFindings
        let outcome = findings > 0 ? (findings == 1 ? "1 finding" : "\(findings) findings") : "clean"
        scan = ScanSummary(
            symbol: scanState == .good ? "checkmark.shield" : "exclamationmark.shield",
            state: scanState,
            last: overview.scan.lastScan.map {
                "Last scan \(PopoverModel.relative($0, now: now, locale: locale)), \(outcome)"
            } ?? "Never scanned",
            next: overview.scan.nextScan.map { Self.nextText($0, locale: locale) } ?? "Next: not scheduled"
        )

        actions = overview.actions
        temperatureText = snapshot.temperatureCelsius.map { "\(Int($0.rounded())) °C" }
    }

    private static func nextText(_ date: Date, locale: Locale) -> String {
        let style = Date.FormatStyle(locale: locale).weekday(.abbreviated).hour(.twoDigits(amPM: .omitted)).minute()
        return "Next: \(date.formatted(style))"
    }
}

/// Plain numeric series for the Details sparklines, all in 0...1.
public struct HistorySeries: Equatable, Sendable {
    public var cpu: [Double]
    /// Nil when no sample has a GPU value, so the row is omitted.
    public var gpu: [Double]?
    public var memory: [Double]

    public init(history: [OverviewSample]) {
        cpu = history.map { Self.clamp($0.cpu) }
        let gpuValues = history.compactMap(\.gpu)
        gpu = gpuValues.isEmpty ? nil : gpuValues.map(Self.clamp)
        memory = history.map {
            switch $0.memoryPressure {
            case .normal: 0
            case .warning: 0.5
            case .critical: 1
            }
        }
    }

    private static func clamp(_ value: Double) -> Double {
        min(max(value, 0), 1)
    }
}
