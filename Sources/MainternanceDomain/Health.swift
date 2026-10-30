import Foundation

public enum HealthState: Int, Sendable, Comparable {
    case good, needsAttention, problem

    public static func < (lhs: HealthState, rhs: HealthState) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

public enum CheckID: String, Sendable, CaseIterable {
    case diskSpace, memoryPressure, thermal, batteryHealth, startupItems, lastScan, osUpdate, scannerFindings
}

public enum AppDestination: String, Sendable, CaseIterable {
    case home, cleanup, files, scanner, startup, uninstaller, settings

    /// Whether the screen is backed by a working engine. Screens that still run on invented sample data are
    /// hidden from the sidebar and unreachable by links; their code stays in the repo and comes back one by one.
    public var isAvailable: Bool {
        switch self {
        case .home, .settings: true
        case .files, .cleanup, .startup, .uninstaller, .scanner: false
        }
    }
}

public struct HealthCheck: Sendable, Identifiable, Equatable {
    public var id: CheckID
    public var state: HealthState
    public var title: String
    public var reason: String
    public var destination: AppDestination

    public init(id: CheckID, state: HealthState, title: String, reason: String, destination: AppDestination) {
        self.id = id
        self.state = state
        self.title = title
        self.reason = reason
        self.destination = destination
    }
}

public struct HealthReport: Sendable, Equatable {
    public var checks: [HealthCheck]

    public init(checks: [HealthCheck]) {
        self.checks = checks
    }

    public var overall: HealthState {
        checks.map(\.state).max() ?? .good
    }

    public var attentionChecks: [HealthCheck] {
        checks.filter { $0.state != .good }
    }
}

public struct HealthEvaluator: Sendable {
    public init() {}

    public func evaluate(snapshot: SystemSnapshot, scan: ScanStatus?, now: Date) -> HealthReport {
        var checks = [disk(snapshot)]
        if let pressure = snapshot.memoryPressure {
            checks.append(memory(pressure))
        }
        checks.append(thermal(snapshot))
        if let battery = snapshot.battery {
            checks.append(batteryHealth(battery))
        }
        if let count = snapshot.newStartupItemCount {
            checks.append(startup(count))
        }
        if let scan {
            checks.append(lastScan(scan, now: now))
        }
        if let updateAvailable = snapshot.osUpdateAvailable {
            checks.append(osUpdate(updateAvailable))
        }
        if let scan {
            checks.append(findings(scan))
        }
        return HealthReport(checks: checks)
    }

    private func disk(_ snapshot: SystemSnapshot) -> HealthCheck {
        let total = snapshot.diskTotalBytes
        let state: HealthState
        let reason: String
        if total <= 0 {
            state = .needsAttention
            reason = "Disk size unavailable"
        } else {
            let free = min(max(snapshot.diskFreeBytes, 0), total)
            // Exact integer comparison of free/total against 5% and 15%.
            let freeTimes100 = Self.saturatingMultiply(free, 100)
            if freeTimes100 < Self.saturatingMultiply(total, 5) {
                state = .problem
            } else if freeTimes100 < Self.saturatingMultiply(total, 15) {
                state = .needsAttention
            } else {
                state = .good
            }
            if state == .good {
                reason = "\(Self.formatGigabytes(free)) free"
            } else {
                reason = "Disk \(Self.usedPercent(total: total, free: free))% full"
            }
        }
        return HealthCheck(id: .diskSpace, state: state, title: "Disk space", reason: reason, destination: .cleanup)
    }

    private static func saturatingMultiply(_ value: Int64, _ factor: Int64) -> Int64 {
        let product = value.multipliedReportingOverflow(by: factor)
        return product.overflow ? Int64.max : product.partialValue
    }

    /// Used percent rounded half up using integer math. Requires `total > 0` and `0...total` free.
    private static func usedPercent(total: Int64, free: Int64) -> Int64 {
        let used = total - free
        let scaled = used.multipliedReportingOverflow(by: 100)
        if scaled.overflow {
            // Disks this large are not realistic; fall back to scaled-down division.
            return (used / (total / 100 + 1)).clamped(to: 0 ... 100)
        }
        return (scaled.partialValue + total / 2) / total
    }

    private static func formatGigabytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .decimal
        formatter.allowedUnits = [.useGB]
        formatter.includesUnit = true
        return formatter.string(fromByteCount: bytes)
    }

    private func memory(_ pressure: MemoryPressure) -> HealthCheck {
        let (state, reason): (HealthState, String) = switch pressure {
        case .normal: (.good, "Pressure normal")
        case .warning: (.needsAttention, "Memory pressure elevated")
        case .critical: (.problem, "Memory pressure critical")
        }
        return HealthCheck(id: .memoryPressure, state: state, title: "Memory", reason: reason, destination: .home)
    }

    private func thermal(_ snapshot: SystemSnapshot) -> HealthCheck {
        let (state, reason): (HealthState, String) = switch snapshot.thermal {
        case .nominal, .fair: (.good, "No throttling")
        case .serious: (.needsAttention, "Thermal throttling likely")
        case .critical: (.problem, "Thermal state critical")
        }
        return HealthCheck(id: .thermal, state: state, title: "Thermal", reason: reason, destination: .home)
    }

    private func batteryHealth(_ battery: BatterySnapshot) -> HealthCheck {
        let health = battery.healthPercent
        let low = (health ?? 100) < 80
        let reason = health.map { "Health \($0)%" } ?? "Health unavailable"
        return HealthCheck(
            id: .batteryHealth, state: low ? .needsAttention : .good,
            title: "Battery health", reason: reason, destination: .home
        )
    }

    private func startup(_ count: Int) -> HealthCheck {
        let reason = switch count {
        case ...0: "No new items"
        case 1: "1 new login item"
        default: "\(count) new login items"
        }
        return HealthCheck(
            id: .startupItems, state: count > 0 ? .needsAttention : .good,
            title: "Startup items", reason: reason, destination: .startup
        )
    }

    private func lastScan(_ scan: ScanStatus, now: Date) -> HealthCheck {
        guard let last = scan.lastScan else {
            return HealthCheck(
                id: .lastScan, state: .needsAttention, title: "Last scan",
                reason: "Never scanned", destination: .scanner
            )
        }
        let days = max(0, Int((now.timeIntervalSince(last) / 86400).rounded(.down)))
        let state: HealthState = if days > 30 {
            .problem
        } else if days > 10 {
            .needsAttention
        } else {
            .good
        }
        let reason = switch days {
        case 0: "Today"
        case 1: "1 day ago"
        default: "\(days) days ago"
        }
        return HealthCheck(id: .lastScan, state: state, title: "Last scan", reason: reason, destination: .scanner)
    }

    private func osUpdate(_ available: Bool) -> HealthCheck {
        HealthCheck(
            id: .osUpdate, state: available ? .needsAttention : .good,
            title: "macOS update",
            reason: available ? "Update available" : "Up to date",
            destination: .settings
        )
    }

    private func findings(_ scan: ScanStatus) -> HealthCheck {
        let count = scan.unresolvedFindings
        let reason = switch count {
        case ...0: "No findings"
        case 1: "1 unresolved finding"
        default: "\(count) unresolved findings"
        }
        return HealthCheck(
            id: .scannerFindings, state: count > 0 ? .problem : .good,
            title: "Scanner findings", reason: reason, destination: .scanner
        )
    }
}

private extension Int64 {
    func clamped(to range: ClosedRange<Int64>) -> Int64 {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}
