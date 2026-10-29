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
        /// Nil when there is no scanner, so only one line is shown.
        public var next: String?
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

        tiles = Self.makeTiles(snapshot: snapshot, report: report)
        scan = Self.makeScan(overview: overview, now: now, locale: locale)

        actions = overview.actions
        temperatureText = Self.temperatureText(snapshot.temperatureCelsius)
    }

    /// Nil for a missing or non-finite reading (a sensor can report NaN or infinity), so the row is omitted.
    /// Values beyond the `Int` range are clamped before conversion, which would otherwise trap.
    static func temperatureText(_ celsius: Double?) -> String? {
        guard let celsius, celsius.isFinite else { return nil }
        let bounded = min(max(celsius.rounded(), -1000), 1000)
        return "\(Int(bounded)) °C"
    }

    private static func makeTiles(snapshot: SystemSnapshot, report: HealthReport) -> [Tile] {
        func check(_ id: CheckID) -> HealthCheck? {
            report.checks.first { $0.id == id }
        }

        var tiles = [
            Tile(
                title: "Disk free", symbol: "internaldrive", value: formatBytes(snapshot.diskFreeBytes),
                caption: snapshot.diskTotalBytes > 0 ? "of \(formatBytes(snapshot.diskTotalBytes))" : nil,
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
        return tiles
    }

    private static func makeScan(overview: Overview, now: Date, locale: Locale) -> ScanSummary {
        func check(_ id: CheckID) -> HealthCheck? {
            overview.report.checks.first { $0.id == id }
        }

        guard let scan = overview.scan else {
            return ScanSummary(
                symbol: "shield", state: .good, last: "Scanner not set up yet", next: nil
            )
        }
        let scanState = max(check(.lastScan)?.state ?? .good, check(.scannerFindings)?.state ?? .good)
        let findings = scan.unresolvedFindings
        let outcome = switch findings {
        case ...0: "clean"
        case 1: "1 finding"
        default: "\(findings) findings"
        }
        return ScanSummary(
            symbol: scanState == .good ? "checkmark.shield" : "exclamationmark.shield",
            state: scanState,
            last: scan.lastScan.map {
                "Last scan \(PopoverModel.relative($0, now: now, locale: locale)), \(outcome)"
            } ?? "Never scanned",
            next: scan.nextScan.map { Self.nextText($0, locale: locale) } ?? "Next: not scheduled"
        )
    }

    /// Locale decides the clock (12 h with AM/PM or 24 h); no fixed pattern.
    static func nextText(_ date: Date, locale: Locale, timeZone: TimeZone = .current) -> String {
        let style = Date.FormatStyle(locale: locale, timeZone: timeZone).weekday(.abbreviated).hour().minute()
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
