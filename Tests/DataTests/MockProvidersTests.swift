import Foundation
import MainternanceData
import MainternanceDomain
import Testing

struct MockProvidersTests {
    private let fixedNow = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func mockSnapshotYieldsTwoAttentionChecks() async {
        let now = fixedNow
        let snapshot = await MockSystemSnapshotProvider().currentSnapshot()
        let scan = await MockScanStatusProvider(now: { now }).currentStatus()
        let report = HealthEvaluator().evaluate(snapshot: snapshot, scan: scan, now: now)

        #expect(report.overall == .needsAttention)
        #expect(report.attentionChecks.count == 2)
        let disk = report.attentionChecks.first { $0.id == .diskSpace }
        let startup = report.attentionChecks.first { $0.id == .startupItems }
        #expect(disk?.reason == "Disk 91% full")
        #expect(startup?.reason == "3 new login items")
    }

    @Test func mockScanStatusDates() async throws {
        let now = fixedNow
        let scan = try #require(await MockScanStatusProvider(now: { now }).currentStatus())
        #expect(scan.unresolvedFindings == 0)
        #expect(scan.lastScan == now.addingTimeInterval(-3 * 86400))
        let next = try #require(scan.nextScan)
        #expect(next > now)
        let parts = Calendar.current.dateComponents([.weekday, .hour, .minute], from: next)
        #expect(parts.weekday == 1)
        #expect(parts.hour == 2)
        #expect(parts.minute == 0)
    }

    @Test func mockActions() async {
        let actions = await MockSuggestedActionsProvider().suggestedActions()
        #expect(actions.map(\.destination) == [.cleanup, .startup, .files])
        #expect(actions.map(\.symbol) == ["sparkles", "power", "doc.on.doc"])
        #expect(actions.map(\.title) == ["Clear 12 GB of junk", "Review 3 new login items", "4 GB of duplicates found"])
    }
}
