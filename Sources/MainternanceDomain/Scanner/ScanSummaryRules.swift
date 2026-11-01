import Foundation

/// Pure mapping from a finished scan to what Home health needs.
public enum ScanSummaryRules {
    /// A cancelled scan does not count as a last scan.
    public static func lastScanDate(summary: ScanSummary) -> Date? {
        summary.cancelled ? nil : summary.endedAt
    }

    /// Never scanned (nil summary) gives `lastScan` nil. The caller decides whether a scanner exists at all:
    /// with no scanner installed it passes no `ScanStatus` to health (unknown stays nil). Detections that could not
    /// be attributed to a file still count as unresolved: they are real until proven otherwise.
    public static func scanStatus(from summary: ScanSummary?, unresolvedFindings: Int) -> ScanStatus {
        ScanStatus(
            lastScan: summary.flatMap { lastScanDate(summary: $0) },
            nextScan: nil,
            unresolvedFindings: max(0, unresolvedFindings) + (summary?.unattributedDetections ?? 0)
        )
    }
}
