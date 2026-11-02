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
        let recorded: RecordedScanStatus?
        switch await store.loadState() {
        case .nothingSaved:
            recorded = nil
        case let .saved(status):
            recorded = status
        case .unreadable:
            // The file is there and cannot be read: not "never scanned", not "no findings".
            return ScanStatus(lastScan: nil, nextScan: nil, unresolvedFindings: 0, savedResultsUnreadable: true)
        }
        let findings = recorded?.findings ?? []
        let status = ScanSummaryRules.scanStatus(
            from: recorded?.summary,
            unresolvedFindings: findings.count + (recorded?.unattributedFromIncompleteScan ?? 0),
            lastScanDidNotFinish: recorded?.scanDidNotFinish ?? false
        )
        // A damaged last-scan record with listed findings: a scan did run when it reported them, so the latest
        // detection date stands in for the last scan instead of a false "Never scanned". Findings stay red.
        let latest = recorded?.summaryUnreadable == true ? findings.map(\.foundAt).max() : nil
        return ScanStatus(
            lastScan: latest ?? status.lastScan, nextScan: nil, unresolvedFindings: status.unresolvedFindings,
            lastScanDidNotFinish: status.lastScanDidNotFinish,
            savedResultsUnreadable: recorded.map { $0.earlierResultsUnreadable || $0.summaryUnreadable } ?? false
        )
    }
}
