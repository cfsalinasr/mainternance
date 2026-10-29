import Foundation
import MainternanceDomain

public struct MockScanStatusProvider: ScanStatusProviding {
    private let now: @Sendable () -> Date

    public init(now: @escaping @Sendable () -> Date = Date.init) {
        self.now = now
    }

    public func currentStatus() async -> ScanStatus {
        let current = now()
        let next = Calendar.current.nextDate(
            after: current,
            matching: DateComponents(hour: 2, minute: 0, weekday: 1),
            matchingPolicy: .nextTime
        )
        return ScanStatus(
            lastScan: current.addingTimeInterval(-3 * 86400),
            nextScan: next,
            unresolvedFindings: 0
        )
    }
}
