import Foundation
import MainternanceDomain
import Testing

private let fixedNow = Date(timeIntervalSince1970: 1_800_000_000)

private let snapshot = SystemSnapshot(
    diskTotalBytes: 460_000_000_000, diskFreeBytes: 20_000_000_000, memoryPressure: .warning,
    thermal: .nominal, cpuUsage: 0.2, gpuUsage: nil, temperatureCelsius: nil, battery: nil,
    newStartupItemCount: 1, osUpdateAvailable: true
)
private let scan = ScanStatus(lastScan: fixedNow.addingTimeInterval(-86400 * 3), nextScan: nil, unresolvedFindings: 2)
private let action = SuggestedAction(
    id: "a", title: "Clean up", detail: "Free space", symbol: "trash", destination: .cleanup
)

private struct FakeSnapshots: SystemSnapshotProviding {
    func currentSnapshot() async -> SystemSnapshot {
        snapshot
    }
}

private struct FakeScans: ScanStatusProviding {
    func currentStatus() async -> ScanStatus {
        scan
    }
}

private struct FakeActions: SuggestedActionsProviding {
    func suggestedActions() async -> [SuggestedAction] {
        [action]
    }
}

struct LoadOverviewTests {
    @Test func combinesProvidersAndEvaluatesWithInjectedNow() async {
        let load = LoadOverview(
            snapshots: FakeSnapshots(), scans: FakeScans(), actions: FakeActions(), now: { fixedNow }
        )
        let overview = await load()
        #expect(overview.snapshot == snapshot)
        #expect(overview.scan == scan)
        #expect(overview.report == HealthEvaluator().evaluate(snapshot: snapshot, scan: scan, now: fixedNow))
        #expect(overview.actions == [action])
    }
}
