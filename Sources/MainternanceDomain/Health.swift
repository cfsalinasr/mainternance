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

public enum AppDestination: String, Sendable {
    case home, cleanup, files, scanner, startup, uninstaller, settings
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

    public func evaluate(snapshot: SystemSnapshot, scan: ScanStatus, now: Date) -> HealthReport {
        var checks = [disk(snapshot), memory(snapshot), thermal(snapshot)]
        if let battery = snapshot.battery {
            checks.append(batteryHealth(battery))
        }
        checks += [startup(snapshot), lastScan(scan, now: now), osUpdate(snapshot), findings(scan)]
        return HealthReport(checks: checks)
    }

    private func disk(_ snapshot: SystemSnapshot) -> HealthCheck {
        let total = snapshot.diskTotalBytes
        let free = snapshot.diskFreeBytes
        let state: HealthState
        let reason: String
        if total <= 0 {
            state = .needsAttention
            reason = "Disk size unavailable"
        } else {
            // Exact integer comparison of free/total against 15% and 5%.
            let scaled = free.multipliedReportingOverflow(by: 100)
            let freeTimes100 = scaled.overflow ? Int64.max : scaled.partialValue
            let totalFloor = { (percent: Int64) -> Int64 in
                let product = total.multipliedReportingOverflow(by: percent)
                return product.overflow ? Int64.max : product.partialValue
            }
            if freeTimes100 < totalFloor(5) {
                state = .problem
            } else if freeTimes100 < totalFloor(15) {
                state = .needsAttention
            } else {
                state = .good
            }
            if state == .good {
                reason = "\(Self.formatGigabytes(free)) free"
            } else {
                let used = ((1 - Double(free) / Double(total)) * 100).rounded()
                reason = "Disk \(Int(used))% full"
            }
        }
        return HealthCheck(id: .diskSpace, state: state, title: "Disk space", reason: reason, destination: .cleanup)
    }

    private static func formatGigabytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .decimal
        formatter.allowedUnits = [.useGB]
        formatter.includesUnit = true
        return formatter.string(fromByteCount: bytes)
    }

    private func memory(_ snapshot: SystemSnapshot) -> HealthCheck {
        let (state, reason): (HealthState, String) = switch snapshot.memoryPressure {
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

    private func startup(_ snapshot: SystemSnapshot) -> HealthCheck {
        let count = snapshot.newStartupItemCount
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
        let state: HealthState = days > 30 ? .problem : (days > 10 ? .needsAttention : .good)
        let reason = switch days {
        case 0: "Today"
        case 1: "1 day ago"
        default: "\(days) days ago"
        }
        return HealthCheck(id: .lastScan, state: state, title: "Last scan", reason: reason, destination: .scanner)
    }

    private func osUpdate(_ snapshot: SystemSnapshot) -> HealthCheck {
        HealthCheck(
            id: .osUpdate, state: snapshot.osUpdateAvailable ? .needsAttention : .good,
            title: "macOS update",
            reason: snapshot.osUpdateAvailable ? "Update available" : "Up to date",
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
