import Foundation
import MainternanceDomain
import Testing

private let now = Date(timeIntervalSince1970: 1_800_000_000)
private let day: TimeInterval = 86400
private let gigabyte: Int64 = 1_000_000_000

private func makeSnapshot(
    total: Int64 = 460 * gigabyte,
    free: Int64 = 200 * gigabyte,
    memory: MemoryPressure = .normal,
    thermal: ThermalLevel = .nominal,
    battery: BatterySnapshot? = BatterySnapshot(percent: 80, isCharging: false, healthPercent: 91, cycleCount: 100),
    startup: Int = 0,
    osUpdate: Bool = false
) -> SystemSnapshot {
    SystemSnapshot(
        diskTotalBytes: total, diskFreeBytes: free, memoryPressure: memory, thermal: thermal,
        cpuUsage: 0.1, gpuUsage: nil, temperatureCelsius: nil, battery: battery,
        newStartupItemCount: startup, osUpdateAvailable: osUpdate
    )
}

private func healthyScan() -> ScanStatus {
    ScanStatus(lastScan: now.addingTimeInterval(-2 * day), nextScan: nil, unresolvedFindings: 0)
}

private func check(
    _ id: CheckID,
    snapshot: SystemSnapshot = makeSnapshot(),
    scan: ScanStatus = healthyScan()
) -> HealthCheck? {
    HealthEvaluator().evaluate(snapshot: snapshot, scan: scan, now: now).checks.first { $0.id == id }
}

private func scan(daysAgo: Double?, findings: Int = 0) -> ScanStatus {
    ScanStatus(lastScan: daysAgo.map { now.addingTimeInterval(-$0 * day) }, nextScan: nil, unresolvedFindings: findings)
}

struct HealthEvaluatorTests {
    @Test func allHealthy() {
        let report = HealthEvaluator().evaluate(snapshot: makeSnapshot(), scan: healthyScan(), now: now)
        #expect(report.overall == .good)
        #expect(report.attentionChecks.isEmpty)
        #expect(report.checks.map(\.id) == CheckID.allCases)
    }

    @Test func emptyReportIsGood() {
        #expect(HealthReport(checks: []).overall == .good)
    }

    @Test func diskBoundaries() {
        #expect(check(.diskSpace, snapshot: makeSnapshot(total: 100, free: 15))?.state == .good)
        #expect(check(.diskSpace, snapshot: makeSnapshot(total: 100, free: 14))?.state == .needsAttention)
        #expect(check(.diskSpace, snapshot: makeSnapshot(total: 100, free: 5))?.state == .needsAttention)
        #expect(check(.diskSpace, snapshot: makeSnapshot(total: 100, free: 4))?.state == .problem)
        #expect(check(.diskSpace)?.destination == .cleanup)
    }

    @Test func diskReasons() {
        let attention = check(.diskSpace, snapshot: makeSnapshot(total: 460 * gigabyte, free: 41 * gigabyte))
        #expect(attention?.state == .needsAttention)
        #expect(attention?.reason == "Disk 91% full")
        let good = check(.diskSpace, snapshot: makeSnapshot(total: 460 * gigabyte, free: 41 * gigabyte * 10))
        #expect(good?.reason == "410 GB free")
        #expect(check(.diskSpace, snapshot: makeSnapshot(total: 500 * gigabyte, free: 100 * gigabyte))?
            .reason == "100 GB free")
    }

    @Test func diskCorruptInputsAreClamped() {
        let negative = check(.diskSpace, snapshot: makeSnapshot(total: 100, free: -50))
        #expect(negative?.state == .problem)
        #expect(negative?.reason == "Disk 100% full")
        let over = check(.diskSpace, snapshot: makeSnapshot(total: 100 * gigabyte, free: 150 * gigabyte))
        #expect(over?.state == .good)
        #expect(over?.reason == "100 GB free")
    }

    @Test func diskPercentRoundsHalfUp() {
        // 12.5% used is not displayed (state good); pin .5 cases that are: 87.5% used -> 88.
        let result = check(.diskSpace, snapshot: makeSnapshot(total: 8 * gigabyte, free: 7 * gigabyte))
        #expect(result?.state == .good)
        let exact = check(.diskSpace, snapshot: makeSnapshot(total: 200, free: 25))
        #expect(exact?.reason == "Disk 88% full")
    }

    @Test func diskSizeUnavailable() {
        for total: Int64 in [0, -5] {
            let result = check(.diskSpace, snapshot: makeSnapshot(total: total, free: 10))
            #expect(result?.state == .needsAttention)
            #expect(result?.reason == "Disk size unavailable")
        }
    }

    @Test func memoryMapping() {
        #expect(check(.memoryPressure, snapshot: makeSnapshot(memory: .normal))?.state == .good)
        #expect(check(.memoryPressure, snapshot: makeSnapshot(memory: .normal))?.reason == "Pressure normal")
        #expect(check(.memoryPressure, snapshot: makeSnapshot(memory: .warning))?.state == .needsAttention)
        #expect(check(.memoryPressure, snapshot: makeSnapshot(memory: .critical))?.state == .problem)
    }

    @Test func thermalMapping() {
        #expect(check(.thermal, snapshot: makeSnapshot(thermal: .nominal))?.reason == "No throttling")
        #expect(check(.thermal, snapshot: makeSnapshot(thermal: .fair))?.state == .good)
        #expect(check(.thermal, snapshot: makeSnapshot(thermal: .serious))?.state == .needsAttention)
        #expect(check(.thermal, snapshot: makeSnapshot(thermal: .critical))?.state == .problem)
    }

    @Test func batteryRules() {
        #expect(check(.batteryHealth, snapshot: makeSnapshot(battery: nil)) == nil)
        let report = HealthEvaluator().evaluate(snapshot: makeSnapshot(battery: nil), scan: healthyScan(), now: now)
        #expect(report.checks.count == CheckID.allCases.count - 1)
        func battery(_ health: Int?) -> BatterySnapshot {
            BatterySnapshot(percent: 50, isCharging: false, healthPercent: health, cycleCount: nil)
        }
        #expect(check(.batteryHealth, snapshot: makeSnapshot(battery: battery(79)))?.state == .needsAttention)
        #expect(check(.batteryHealth, snapshot: makeSnapshot(battery: battery(80)))?.state == .good)
        #expect(check(.batteryHealth, snapshot: makeSnapshot(battery: battery(nil)))?.state == .good)
        #expect(check(.batteryHealth, snapshot: makeSnapshot(battery: battery(91)))?.reason == "Health 91%")
    }

    @Test func startupItems() {
        #expect(check(.startupItems, snapshot: makeSnapshot(startup: 0))?.state == .good)
        #expect(check(.startupItems, snapshot: makeSnapshot(startup: 0))?.reason == "No new items")
        #expect(check(.startupItems, snapshot: makeSnapshot(startup: 1))?.reason == "1 new login item")
        #expect(check(.startupItems, snapshot: makeSnapshot(startup: 3))?.reason == "3 new login items")
        #expect(check(.startupItems, snapshot: makeSnapshot(startup: 3))?.state == .needsAttention)
    }

    @Test func lastScanRules() {
        #expect(check(.lastScan, scan: scan(daysAgo: nil))?.state == .needsAttention)
        #expect(check(.lastScan, scan: scan(daysAgo: nil))?.reason == "Never scanned")
        #expect(check(.lastScan, scan: scan(daysAgo: 10))?.state == .good)
        #expect(check(.lastScan, scan: scan(daysAgo: 10))?.reason == "10 days ago")
        #expect(check(.lastScan, scan: scan(daysAgo: 11))?.state == .needsAttention)
        #expect(check(.lastScan, scan: scan(daysAgo: 30))?.state == .needsAttention)
        #expect(check(.lastScan, scan: scan(daysAgo: 31))?.state == .problem)
        #expect(check(.lastScan, scan: scan(daysAgo: -1))?.state == .good)
    }

    @Test func osUpdate() {
        #expect(check(.osUpdate, snapshot: makeSnapshot(osUpdate: false))?.reason == "Up to date")
        #expect(check(.osUpdate, snapshot: makeSnapshot(osUpdate: true))?.state == .needsAttention)
    }

    @Test func scannerFindings() {
        #expect(check(.scannerFindings, scan: scan(daysAgo: 1, findings: 0))?.reason == "No findings")
        #expect(check(.scannerFindings, scan: scan(daysAgo: 1, findings: 2))?.state == .problem)
    }

    @Test func overallAndAttention() {
        let report = HealthEvaluator().evaluate(
            snapshot: makeSnapshot(memory: .warning, startup: 1), scan: scan(daysAgo: 1, findings: 2), now: now
        )
        #expect(report.overall == .problem)
        #expect(Set(report.attentionChecks.map(\.id)) == [.memoryPressure, .startupItems, .scannerFindings])
        #expect(report.attentionChecks.allSatisfy { $0.state != .good })
    }
}
