import Foundation
import MainternanceDomain

/// Home's scanner status, read from what the Scanner screen persisted.
///
/// While no scanning engine is installed it returns nil, so health has no scan checks at all and the scanner row
/// stays "Not set up yet" (unknown is never turned into a status). Once the engine is installed, no stored scan
/// means "present, never completed a scan" (amber), and findings, attributed or not, make health red. Unattributed
/// detections of a cancelled or failed scan count as findings until a completed scan replaces them.
public struct StoredScanStatusProvider: ScanStatusProviding {
    private let store: ScanStatusStore
    private let isEngineInstalled: @Sendable () -> Bool

    public init(store: ScanStatusStore, isEngineInstalled: @escaping @Sendable () -> Bool) {
        self.store = store
        self.isEngineInstalled = isEngineInstalled
    }

    public func currentStatus() async -> ScanStatus? {
        guard isEngineInstalled() else { return nil }
        let stored = await store.load()
        let findings = stored?.findings ?? []
        let status = ScanSummaryRules.scanStatus(
            from: stored?.summary,
            unresolvedFindings: findings.count + (stored?.unattributedFromIncompleteScan ?? 0),
            lastScanDidNotFinish: stored?.scanDidNotFinish ?? false
        )
        // A damaged last-scan record with listed findings: a scan did run when it reported them, so the latest
        // detection date stands in for the last scan instead of a false "Never scanned". Findings stay red.
        guard stored?.summaryUnreadable == true, let latest = findings.map(\.foundAt).max() else { return status }
        return ScanStatus(
            lastScan: latest, nextScan: nil, unresolvedFindings: status.unresolvedFindings,
            lastScanDidNotFinish: status.lastScanDidNotFinish
        )
    }
}
