import Foundation
import MainternanceDomain
@testable import MainternancePresentation
import SwiftUI
import Testing

struct HomeModelTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let locale = Locale(identifier: "en_US")

    private func overview(
        battery: BatterySnapshot? = nil,
        checks: [HealthCheck] = [],
        scan: ScanStatus? = ScanStatus(lastScan: nil, nextScan: nil, unresolvedFindings: 0),
        snapshot: SystemSnapshot? = nil
    ) -> Overview {
        Overview(
            snapshot: snapshot ?? makeSnapshot(battery: battery),
            scan: scan, report: HealthReport(checks: checks), actions: []
        )
    }

    private func check(_ id: CheckID, _ state: HealthState, _ reason: String, _ target: AppDestination) -> HealthCheck {
        HealthCheck(id: id, state: state, title: reason, reason: reason, destination: target)
    }

    @Test func bannerJoinsAttentionReasonsAsDeepLinks() {
        let model = HomeModel(
            overview: overview(checks: [
                check(.diskSpace, .needsAttention, "Disk 91% full", .cleanup),
                check(.memoryPressure, .good, "Pressure normal", .home),
                check(.startupItems, .needsAttention, "3 new login items", .startup)
            ]),
            now: now, locale: locale
        )
        #expect(model.banner.state == .needsAttention)
        #expect(model.banner.reasons.map(\.text) == ["Disk 91% full", "3 new login items"])
        #expect(model.banner.reasons.map(\.destination) == [.cleanup, .startup])
    }

    @Test func goodBannerHasNoReasons() {
        let model = HomeModel(overview: overview(checks: [check(.diskSpace, .good, "41 GB free", .cleanup)]))
        #expect(model.banner.state == .good)
        #expect(model.banner.reasons.isEmpty)
    }

    @Test func batteryTileOmittedWhenNil() {
        let model = HomeModel(overview: overview(), now: now, locale: locale)
        #expect(model.tiles.map(\.title) == ["Disk free"])
    }

    @Test func batteryTileCaptionOmitsMissingParts() {
        let full = HomeModel(
            overview: overview(battery: BatterySnapshot(
                percent: 82,
                isCharging: false,
                healthPercent: 91,
                cycleCount: 214
            )),
            now: now, locale: locale
        )
        #expect(full.tiles.last?.value == "82%")
        #expect(full.tiles.last?.caption == "health 91% · 214 cycles")

        let partial = HomeModel(
            overview: overview(battery: BatterySnapshot(
                percent: 82,
                isCharging: false,
                healthPercent: nil,
                cycleCount: 214
            )),
            now: now, locale: locale
        )
        #expect(partial.tiles.last?.caption == "214 cycles")

        let none = HomeModel(
            overview: overview(battery: BatterySnapshot(
                percent: 82,
                isCharging: false,
                healthPercent: nil,
                cycleCount: nil
            )),
            now: now, locale: locale
        )
        #expect(none.tiles.last?.caption == nil)
    }

    @Test func tilesCarryDomainStateAndDestination() {
        let model = HomeModel(
            overview: overview(checks: [
                check(.diskSpace, .problem, "Disk 97% full", .cleanup),
                check(.memoryPressure, .good, "Pressure normal", .home),
                check(.thermal, .good, "No throttling", .home)
            ]),
            now: now, locale: locale
        )
        #expect(model.tiles.map(\.title) == ["Disk free", "Memory", "Thermal"])
        #expect(model.tiles[0].state == .problem)
        #expect(model.tiles[0].destination == .cleanup)
        #expect(model.tiles[0].caption == "of 500 GB")
        #expect(model.tiles[2].caption == "No throttling")
    }

    @Test func scanSummaryWords() {
        let model = HomeModel(
            overview: overview(scan: ScanStatus(
                lastScan: now.addingTimeInterval(-3 * 86400), nextScan: now.addingTimeInterval(86400),
                unresolvedFindings: 0
            )),
            now: now, locale: locale
        )
        #expect(model.scan.last == "Last scan 3 days ago, clean")
        #expect(model.scan.next?.hasPrefix("Next: ") == true)
    }

    @Test func nextScanTimeFollowsLocaleClock() {
        // Sunday 2027-01-10 14:00 UTC; the formatter below uses the same fixed zone as the date.
        let sunday = Date(timeIntervalSince1970: 1_799_589_600)
        let usText = HomeModel.nextText(sunday, locale: Locale(identifier: "en_US"), timeZone: .gmt)
        let gbText = HomeModel.nextText(sunday, locale: Locale(identifier: "en_GB"), timeZone: .gmt)
        #expect(usText.contains("2:00") && usText.contains("PM") && usText.hasPrefix("Next: Sun"))
        #expect(gbText == "Next: Sun 14:00")
    }

    @Test func scanSummaryWithoutDatesIsSafe() {
        let model = HomeModel(overview: overview(), now: now, locale: locale)
        #expect(model.scan.last == "Never scanned")
        #expect(model.scan.next == "Next: not scheduled")
    }

    @Test func missingScannerShowsSingleNotSetUpLine() {
        let model = HomeModel(overview: overview(scan: nil), now: now, locale: locale)
        #expect(model.scan.last == "Scanner not set up yet")
        #expect(model.scan.next == nil)
        #expect(model.scan.state == .good)
        #expect(!model.scan.last.contains("Never"))
        #expect(!model.scan.last.contains("Next"))
    }

    @Test func findingsReplaceCleanWord() {
        let model = HomeModel(
            overview: overview(scan: ScanStatus(lastScan: now, nextScan: nil, unresolvedFindings: 2)),
            now: now, locale: locale
        )
        #expect(model.scan.last.hasSuffix("2 findings"))
    }

    @Test func temperatureOmittedWhenNil() {
        #expect(HomeModel(overview: overview()).temperatureText == nil)
        let hot = overview(snapshot: makeSnapshot(temperatureCelsius: 54.4))
        #expect(HomeModel(overview: hot).temperatureText == "54 °C")
    }

    @Test func seriesOmitsGpuWithoutValuesAndClamps() {
        let stamp = Date()
        let samples = [
            OverviewSample(cpu: 1.4, gpu: nil, memoryPressure: .normal, at: stamp),
            OverviewSample(cpu: 0.2, gpu: nil, memoryPressure: .critical, at: stamp)
        ]
        let series = HistorySeries(history: samples)
        expectClose(series.cpu ?? [], [1, 0.2])
        #expect(series.gpu == nil)
        expectClose(series.memory ?? [], [0, 1])
        let withGpu = HistorySeries(history: [
            OverviewSample(cpu: 0, gpu: 0.5, memoryPressure: .warning, at: stamp),
            OverviewSample(cpu: 0, gpu: 1.5, memoryPressure: .warning, at: stamp)
        ])
        expectClose(withGpu.gpu ?? [], [0.5, 1])
    }

    private func expectClose(
        _ actual: [Double],
        _ expected: [Double],
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        #expect(actual.count == expected.count, sourceLocation: sourceLocation)
        for (value, want) in zip(actual, expected) {
            #expect(abs(value - want) < 1e-9, sourceLocation: sourceLocation)
        }
    }

    @Test func nonFiniteTemperatureIsOmittedInsteadOfTrapping() {
        for bad in [Double.nan, .infinity, -.infinity] {
            let hot = overview(snapshot: makeSnapshot(temperatureCelsius: bad))
            #expect(HomeModel(overview: hot).temperatureText == nil)
        }
    }

    @Test func extremeFiniteTemperatureIsClampedInsteadOfTrapping() {
        #expect(HomeModel.temperatureText(1e300) == "1000 °C")
        #expect(HomeModel.temperatureText(-1e300) == "-1000 °C")
        #expect(HomeModel.temperatureText(-3.6) == "-4 °C")
    }

    @Test func unknownMemoryOmitsTheMemoryTile() {
        var shot = makeSnapshot()
        shot.memoryPressure = nil
        let checks = [
            check(.diskSpace, .good, "ok", .cleanup), check(.memoryPressure, .good, "Pressure normal", .home),
            check(.thermal, .good, "No throttling", .home)
        ]
        let model = HomeModel(overview: overview(checks: checks, snapshot: shot))
        #expect(model.tiles.map(\.title) == ["Disk free", "Thermal"])
    }

    @Test func unreadableDiskTileShowsUnavailableWithoutCaption() throws {
        var shot = makeSnapshot()
        shot.diskTotalBytes = 0
        shot.diskFreeBytes = 0
        let model = HomeModel(overview: overview(snapshot: shot))
        let tile = try #require(model.tiles.first)
        #expect(tile.title == "Disk free")
        #expect(tile.value == "Unavailable")
        #expect(tile.caption == nil)
    }

    @Test func seriesSkipsNilCpuAndMemorySamples() {
        let stamp = Date()
        let samples = [
            OverviewSample(cpu: nil, gpu: nil, memoryPressure: nil, at: stamp),
            OverviewSample(cpu: 0.5, gpu: nil, memoryPressure: .warning, at: stamp),
            OverviewSample(cpu: 0.25, gpu: nil, memoryPressure: nil, at: stamp)
        ]
        let series = HistorySeries(history: samples)
        expectClose(series.cpu ?? [], [0.5, 0.25])
        #expect(series.memory == nil) // Only one sample knows the pressure: nothing to draw.
        let none = HistorySeries(history: [OverviewSample(cpu: nil, gpu: nil, memoryPressure: nil, at: stamp)])
        #expect(none.cpu == nil)
        #expect(none.memory == nil)
        #expect(HistorySeries(history: []).cpu == nil)
    }

    @Test func sparklineWithFewerThanTwoPointsDrawsNothing() {
        let rect = CGRect(x: 0, y: 0, width: 100, height: 20)
        #expect(Sparkline(values: []).path(in: rect).isEmpty)
        #expect(Sparkline(values: [0.5]).path(in: rect).isEmpty)
        #expect(!Sparkline(values: [0.5, 0.7]).path(in: rect).isEmpty)
    }

    @Test func emptySuggestionsHaveAOneLineEmptyState() {
        #expect(HomeModel(overview: overview()).actions.isEmpty)
        #expect(HomeModel(overview: overview()).suggestionsEmptyText == "Nothing to suggest yet")
    }
}

extension HomeModelTests {
    @Test func suggestionsEmptyTextAppearsOnlyWithoutActions() {
        let empty = HomeModel(overview: overview())
        #expect(empty.suggestionsEmptyText == "Nothing to suggest yet")
        let action = SuggestedAction(
            id: "x", title: "Free space", detail: "d", symbol: "sparkles", destination: .cleanup
        )
        let full = HomeModel(overview: Overview(
            snapshot: makeSnapshot(), scan: nil, report: HealthReport(checks: []), actions: [action]
        ))
        #expect(full.suggestionsEmptyText == nil)
    }

    @Test func goodBannerSaysAvailableWhenSomeChecksAreMissing() {
        let partial = HomeModel(overview: overview(checks: [check(.diskSpace, .good, "ok", .home)]))
        #expect(partial.banner.goodText == "All available checks passed")
        let all = CheckID.allCases.map { check($0, .good, "ok", .home) }
        #expect(HomeModel(overview: overview(checks: all)).banner.goodText == "All checks passed")
    }
}
