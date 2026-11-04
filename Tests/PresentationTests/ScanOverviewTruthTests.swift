import Foundation
import MainternanceDomain
import MainternancePresentation
import Testing

private struct FixedScanStatus: ScanStatusProviding {
    let status: ScanStatus?

    func currentStatus() async -> ScanStatus? {
        status
    }
}

/// Home and the popover say when the weekly scan runs next, or that it is off, and the popover's scan rows say
/// what the health report says.
struct ScanOverviewTruthTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let locale = Locale(identifier: "en_US")

    private func provider(_ base: ScanStatus?, enabled: Bool, lastRun: Date? = nil) -> ScheduledScanStatusProvider {
        var prefs = AppPreferences.defaults
        prefs.weeklyScanEnabled = enabled
        prefs.lastScheduledRun = lastRun
        let fixed = prefs
        let moment = now
        return ScheduledScanStatusProvider(
            base: FixedScanStatus(status: base), preferences: { fixed }, now: { moment }, calendar: utcCalendar
        )
    }

    private let installed = ScanStatus(lastScan: nil, nextScan: nil, unresolvedFindings: 0)

    // MARK: Next scan

    @Test func aWeeklyScanThatIsOnHasANextScan() async throws {
        let status = try #require(await provider(installed, enabled: true, lastRun: now).currentStatus())
        let next = try #require(status.nextScan)
        #expect(next > now)
        #expect(next <= now.addingTimeInterval(7 * 86400))
    }

    @Test func aWeeklyScanThatIsOffHasNone() async throws {
        let status = try #require(await provider(installed, enabled: false).currentStatus())
        #expect(status.nextScan == nil)
    }

    @Test func noScannerStaysNoScanner() async {
        #expect(await provider(nil, enabled: true).currentStatus() == nil)
    }

    @Test func homeAndPopoverSayTheWeeklyScanIsOff() {
        let overview = overview(installed)
        #expect(HomeModel(overview: overview, now: now, locale: locale).scan.next == "Weekly scan off")
        let popover = PopoverModel(overview: overview, now: now, locale: locale)
        #expect(popover.rows.first { $0.title == "Next scan" }?.value == "Weekly scan off")
        #expect(!popover.rows.contains { $0.value.contains("Not scheduled") })
    }

    // MARK: Popover rows follow the report

    private func overview(_ scan: ScanStatus) -> Overview {
        let snapshot = SystemSnapshot(
            diskTotalBytes: 460_000_000_000, diskFreeBytes: 200_000_000_000, memoryPressure: .normal,
            thermal: .nominal, cpuUsage: 0.1, gpuUsage: nil, temperatureCelsius: nil, battery: nil,
            newStartupItemCount: 0, osUpdateAvailable: false
        )
        return Overview(
            snapshot: snapshot, scan: scan,
            report: HealthEvaluator().evaluate(snapshot: snapshot, scan: scan, now: now), actions: []
        )
    }

    private func row(_ title: String, _ scan: ScanStatus) -> PopoverModel.Row? {
        PopoverModel(overview: overview(scan), now: now, locale: locale).rows.first { $0.title == title }
    }

    @Test func unreadableSavedResultsAreNotNever() {
        let scan = ScanStatus(lastScan: nil, nextScan: nil, unresolvedFindings: 0, savedResultsUnreadable: true)
        let last = row("Last scan", scan)
        #expect(last?.value == "Could not be read")
        #expect(last?.state == .needsAttention)
        #expect(row("Findings", scan) == nil) // the report makes no claim, so neither does the popover
    }

    @Test func anUnfinishedScanIsNotShownAsAFinishedOne() {
        let scan = ScanStatus(
            lastScan: now.addingTimeInterval(-3 * 86400), nextScan: nil, unresolvedFindings: 0,
            lastScanDidNotFinish: true
        )
        let last = row("Last scan", scan)
        #expect(last?.value == "Did not finish")
        #expect(last?.state == .needsAttention)
    }

    @Test func anOldScanTakesTheReportsState() {
        let scan = ScanStatus(lastScan: now.addingTimeInterval(-40 * 86400), nextScan: nil, unresolvedFindings: 0)
        #expect(row("Last scan", scan)?.state == .problem)
    }

    @Test func findingsHaveTheirOwnRow() {
        let scan = ScanStatus(lastScan: now.addingTimeInterval(-86400), nextScan: nil, unresolvedFindings: 2)
        let findings = row("Findings", scan)
        #expect(findings?.value == "2 unresolved findings")
        #expect(findings?.state == .problem)
        let clean = ScanStatus(lastScan: now.addingTimeInterval(-86400), nextScan: nil, unresolvedFindings: 0)
        #expect(row("Findings", clean)?.value == "No findings")
        #expect(row("Findings", clean)?.state == .good)
    }
}
