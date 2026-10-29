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
        next: Date? = nil
    ) -> Overview {
        Overview(
            snapshot: snapshot,
            scan: ScanStatus(lastScan: last, nextScan: next, unresolvedFindings: 0),
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

    @Test func fullSnapshotProducesRealValues() {
        let m = model(overview(
            snapshot: snapshot(), last: now.addingTimeInterval(-3 * 86400), next: now.addingTimeInterval(86400)
        ))
        #expect(m.hero.title == "Needs attention")
        #expect(m.hero.symbol == "exclamationmark.shield")
        #expect(m.hero.checkCount == 2)
        #expect(m.hero.checksText == "2 checks")
        #expect(m.metrics.map(\.title) == ["CPU", "Memory", "Thermal", "Battery"])
        #expect(m.metrics.map(\.value) == ["23%", "Green", "Nominal", "82%"])
        #expect(m.metrics.map(\.state) == [.good, .good, .good, .needsAttention])
        #expect(m.metrics[3].symbol == "battery.100percent.bolt")
        #expect(m.rows.map(\.title) == ["Disk free", "Battery health", "Last scan", "Next scan"])
        #expect(m.rows[0].value == "41 GB")
        #expect(m.rows[0].state == .needsAttention)
        #expect(m.rows[1].value == "91%")
        #expect(m.rows[2].value == "3 days ago")
        #expect(m.rows[3].value == "tomorrow")
    }

    @Test func columnStatesComeFromReportChecks() {
        let m = model(overview(snapshot: snapshot(), checks: [
            check(.memoryPressure, .problem), check(.thermal, .needsAttention)
        ]))
        #expect(m.metrics.first { $0.title == "Memory" }?.state == .problem)
        #expect(m.metrics.first { $0.title == "Thermal" }?.state == .needsAttention)
        #expect(m.metrics.first { $0.title == "Battery" }?.state == .good)
    }

    @Test func missingChecksOmitColumnsInsteadOfDefaultingToGood() {
        let m = model(overview(snapshot: snapshot(), checks: []))
        #expect(m.metrics.map(\.title) == ["CPU", "Battery"])
        #expect(m.hero.checksText == nil)
        #expect(m.hero.symbol == "checkmark.shield")
    }

    @Test func nilBatteryOmitsColumnAndHealthRow() {
        let m = model(overview(snapshot: snapshot(battery: nil)))
        #expect(!m.metrics.map(\.title).contains("Battery"))
        #expect(!m.rows.map(\.title).contains("Battery health"))
    }

    @Test func nilHealthPercentOmitsOnlyHealthRow() {
        let battery = BatterySnapshot(percent: 50, isCharging: false, healthPercent: nil, cycleCount: nil)
        let m = model(overview(snapshot: snapshot(battery: battery)))
        #expect(m.metrics.map(\.title).contains("Battery"))
        #expect(!m.rows.map(\.title).contains("Battery health"))
    }

    @Test func nilScansShowNeverAndNotScheduled() {
        let m = model(overview(snapshot: snapshot()))
        #expect(m.rows.first { $0.title == "Last scan" }?.value == "Never")
        #expect(m.rows.first { $0.title == "Next scan" }?.value == "Not scheduled")
    }

    @Test func thermalShowsLevelWordEvenWithTemperature() {
        var s = snapshot()
        s.temperatureCelsius = 71
        s.thermal = .serious
        let m = model(overview(snapshot: s, checks: [check(.thermal, .needsAttention)]))
        #expect(m.metrics.first { $0.title == "Thermal" }?.value == "Serious")
    }

    @Test func visibilityDecision() {
        #expect(WindowVisibility.isVisible(occlusionVisible: true, isKey: false, isClosed: false))
        #expect(WindowVisibility.isVisible(occlusionVisible: false, isKey: true, isClosed: false))
        #expect(!WindowVisibility.isVisible(occlusionVisible: false, isKey: false, isClosed: false))
        #expect(!WindowVisibility.isVisible(occlusionVisible: true, isKey: true, isClosed: true))
    }

    @Test func accessibilityNotesFlagNonGoodStates() {
        #expect(HealthState.good.accessibilityNote.isEmpty)
        #expect(HealthState.needsAttention.accessibilityNote.contains("needs attention"))
        #expect(HealthState.problem.accessibilityNote.contains("problem"))
    }
}
