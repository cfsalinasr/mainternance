import Foundation
import MainternanceDomain
import MainternancePresentation
import Testing

/// Home and the popover built from ONE overview shaped like the live provider's first sample: no CPU value
/// yet, unknown startup items and OS update, no scanner, memory known. Neither may invent a value.
struct LiveStyleOverviewTests {
    private let locale = Locale(identifier: "en_US")
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private struct FirstLiveSample: SystemSnapshotProviding {
        func currentSnapshot() async -> SystemSnapshot {
            SystemSnapshot(
                diskTotalBytes: 494_332_366_848, diskFreeBytes: 278_333_262_487,
                memoryPressure: .normal, thermal: .nominal, cpuUsage: nil,
                gpuUsage: nil, temperatureCelsius: nil,
                battery: BatterySnapshot(percent: 100, isCharging: false, healthPercent: 100, cycleCount: 22),
                newStartupItemCount: nil, osUpdateAvailable: nil
            )
        }
    }

    private struct NoScanner: ScanStatusProviding {
        func currentStatus() async -> ScanStatus? {
            nil
        }
    }

    private func liveStyleOverview() async -> Overview {
        let load = LoadOverview(
            snapshots: FirstLiveSample(), scans: NoScanner(), actions: FakeActions(), now: { [now] in now }
        )
        return await load()
    }

    /// Every user-visible string either model produces.
    private func allTexts(home: HomeModel, popover: PopoverModel) -> [String] {
        var texts = [home.banner.title, home.banner.goodText, home.scan.last]
        texts += [home.scan.next, home.suggestionsEmptyText, home.temperatureText].compactMap(\.self)
        texts += home.banner.reasons.map(\.text)
        texts += home.tiles.flatMap { [$0.title, $0.value, $0.caption].compactMap(\.self) }
        texts += [popover.hero.title, popover.hero.checksText].compactMap(\.self)
        texts += popover.metrics.flatMap { [$0.title, $0.value] }
        texts += popover.rows.flatMap { [$0.title, $0.value] }
        return texts
    }

    @Test func liveStyleOverviewShowsNoMadeUpValues() async throws {
        let overview = await liveStyleOverview()
        try #require(overview.snapshot.cpuUsage == nil)
        try #require(overview.scan == nil)
        let home = HomeModel(overview: overview, now: now, locale: locale)
        let popover = PopoverModel(overview: overview, now: now, locale: locale)
        let texts = allTexts(home: home, popover: popover)
        // Precondition: the collection is not empty and really contains model text.
        try #require(texts.contains("Disk free"))
        try #require(texts.contains("Green"))

        // A "0%" not preceded by a digit ("100%" is a real battery value, "0%" would be invented).
        let zeroPercent = #"(?<![0-9])0\s?%"#
        #expect(!texts.contains { $0.range(of: zeroPercent, options: .regularExpression) != nil })
        try #require("CPU 0%".range(of: zeroPercent, options: .regularExpression) != nil)
        for banned in ["Last scan", "Next scan", "Never", "Not scheduled", "Next:"] {
            #expect(!texts.contains { $0.contains(banned) }, "unexpected \(banned)")
        }
        #expect(!popover.metrics.contains { $0.title == "CPU" })
        #expect(home.banner.goodText == "All available checks passed")
        #expect(home.banner.state == .good)
    }

    @Test func liveStyleOverviewListsExactlyTheChecksThatCanBeMade() async {
        let overview = await liveStyleOverview()
        let ids = Set(overview.report.checks.map(\.id))
        #expect(ids == [.diskSpace, .memoryPressure, .thermal, .batteryHealth])
        #expect(overview.report.checks.count == ids.count)
    }
}
