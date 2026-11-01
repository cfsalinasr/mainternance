import Foundation
import MainternanceDomain

/// Home's scanner status, read from what the Scanner screen persisted.
///
/// While no scanning engine is installed it returns nil, so health has no scan checks at all and the scanner row
/// stays "Not set up yet" (unknown is never turned into a status). Once the engine is installed, no stored scan
/// means "present, never completed a scan" (amber), and findings, attributed or not, make health red.
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
        return ScanSummaryRules.scanStatus(from: stored?.summary, unresolvedFindings: stored?.findings.count ?? 0)
    }
}
