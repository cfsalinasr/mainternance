import Foundation
import MainternanceDomain
import MainternancePresentation
import Testing

struct PopoverModelTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let locale = Locale(identifier: "en_US")

    private func snapshot(battery: BatterySnapshot? = BatterySnapshot(
        percent: 82, isCharging: true, healthPercent: 91, cycleCount: 214
    )) -> SystemSnapshot {
        SystemSnapshot(
            diskTotalBytes: 460_000_000_000, diskFreeBytes: 41_000_000_000,
            memoryPressure: .normal, thermal: .nominal, cpuUsage: 0.23,
            gpuUsage: nil, temperatureCelsius: nil, battery: battery,
            newStartupItemCount: 0, osUpdateAvailable: false
        )
    }

    private func check(_ id: CheckID, _ state: HealthState) -> HealthCheck {
        HealthCheck(id: id, state: state, title: "\(id)", reason: "r", destination: .home)
    }

    private func overview(
        snapshot: SystemSnapshot,
        checks: [HealthCheck]? = nil,
        last: Date? = nil,
        next: Date? = nil,
        hasScanner: Bool = true
    ) -> Overview {
        Overview(
            snapshot: snapshot,
            scan: hasScanner ? ScanStatus(lastScan: last, nextScan: next, unresolvedFindings: 0) : nil,
            report: HealthReport(checks: checks ?? [
                check(.diskSpace, .needsAttention), check(.memoryPressure, .good),
                check(.thermal, .good), check(.batteryHealth, .needsAttention)
            ]),
            actions: []
        )
    }

    private func model(_ overview: Overview) -> PopoverModel {
        PopoverModel(overview: overview, now: now, locale: locale)
    }

    @Test func missingScannerShowsOneNotSetUpRow() {
        let popover = model(overview(snapshot: snapshot(), hasScanner: false))
        #expect(popover.rows.map(\.title) == ["Disk free", "Battery health", "Scanner"])
        #expect(popover.rows.last?.value == "Not set up yet")
        let text = popover.rows.map { "\($0.title) \($0.value)" }.joined(separator: "|")
        #expect(!text.contains("Never"))
        #expect(!text.contains("Not scheduled"))
        #expect(!text.contains("Last scan"))
        #expect(!text.contains("Next scan"))
    }

    @Test func fullSnapshotProducesRealValues() {
        let popover = model(overview(
            snapshot: snapshot(), last: now.addingTimeInterval(-3 * 86400), next: now.addingTimeInterval(86400)
        ))
        #expect(popover.hero.title == "Needs attention")
        #expect(popover.hero.symbol == "exclamationmark.shield")
        #expect(popover.hero.checkCount == 2)
        #expect(popover.hero.checksText == "2 checks")
        #expect(popover.metrics.map(\.title) == ["CPU", "Memory", "Thermal", "Battery"])
        #expect(popover.metrics.map(\.value) == ["23%", "Green", "Nominal", "82%"])
        #expect(popover.metrics.map(\.state) == [.good, .good, .good, .needsAttention])
        #expect(popover.metrics[3].symbol == "battery.100percent.bolt")
        #expect(popover.rows.map(\.title) == ["Disk free", "Battery health", "Last scan", "Next scan"])
        #expect(popover.rows[0].value == "41 GB")
        #expect(popover.rows[0].state == .needsAttention)
        #expect(popover.rows[1].value == "91%")
        #expect(popover.rows[2].value == "3 days ago")
        #expect(popover.rows[3].value == "tomorrow")
    }

    @Test func columnStatesComeFromReportChecks() {
        let popover = model(overview(snapshot: snapshot(), checks: [
            check(.memoryPressure, .problem), check(.thermal, .needsAttention)
        ]))
        #expect(popover.metrics.first { $0.title == "Memory" }?.state == .problem)
        #expect(popover.metrics.first { $0.title == "Thermal" }?.state == .needsAttention)
        #expect(popover.metrics.first { $0.title == "Battery" }?.state == .good)
    }

    @Test func missingChecksOmitColumnsInsteadOfDefaultingToGood() {
        let popover = model(overview(snapshot: snapshot(), checks: []))
        #expect(popover.metrics.map(\.title) == ["CPU", "Battery"])
        #expect(popover.hero.checksText == nil)
        #expect(popover.hero.symbol == "checkmark.shield")
    }

    @Test func nilBatteryOmitsColumnAndHealthRow() {
        let popover = model(overview(snapshot: snapshot(battery: nil)))
        #expect(!popover.metrics.map(\.title).contains("Battery"))
        #expect(!popover.rows.map(\.title).contains("Battery health"))
    }

    @Test func nilHealthPercentOmitsOnlyHealthRow() {
        let battery = BatterySnapshot(percent: 50, isCharging: false, healthPercent: nil, cycleCount: nil)
        let popover = model(overview(snapshot: snapshot(battery: battery)))
        #expect(popover.metrics.map(\.title).contains("Battery"))
        #expect(!popover.rows.map(\.title).contains("Battery health"))
    }

    @Test func nilScansShowNeverAndNotScheduled() {
        let popover = model(overview(snapshot: snapshot()))
        #expect(popover.rows.first { $0.title == "Last scan" }?.value == "Never")
        #expect(popover.rows.first { $0.title == "Next scan" }?.value == "Not scheduled")
    }

    @Test func thermalShowsLevelWordEvenWithTemperature() {
        var hot = snapshot()
        hot.temperatureCelsius = 71
        hot.thermal = .serious
        let popover = model(overview(snapshot: hot, checks: [check(.thermal, .needsAttention)]))
        #expect(popover.metrics.first { $0.title == "Thermal" }?.value == "Serious")
    }

    @Test func accessibilityNotesFlagNonGoodStates() {
        #expect(HealthState.good.accessibilityNote.isEmpty)
        #expect(HealthState.needsAttention.accessibilityNote.contains("needs attention"))
        #expect(HealthState.problem.accessibilityNote.contains("problem"))
    }

    @Test func cpuPercentIsClampedAndNonFiniteShowsZero() {
        let cases: [(Double, String)] = [
            (0.234, "23%"), (-0.5, "0%"), (1.4, "100%"), (.nan, "0%"), (.infinity, "0%"), (-.infinity, "0%")
        ]
        for (usage, text) in cases {
            var busy = snapshot()
            busy.cpuUsage = usage
            let cpu = model(overview(snapshot: busy)).metrics.first { $0.title == "CPU" }
            #expect(cpu?.value == text)
        }
    }
}
