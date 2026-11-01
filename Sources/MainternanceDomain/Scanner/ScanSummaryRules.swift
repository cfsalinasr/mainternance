import Foundation

/// Pure mapping from a finished scan to what Home health needs.
public enum ScanSummaryRules {
    /// A cancelled scan does not count as a last scan.
    public static func lastScanDate(summary: ScanSummary) -> Date? {
        summary.cancelled ? nil : summary.endedAt
    }

    /// A nil `summary` means "the scanner is present but has never completed a scan": `lastScan` is nil, which health
    /// reports as amber "Never scanned". It does NOT mean "no scanner": with no scanner installed the caller passes no
    /// `ScanStatus` at all to health (`ScanStatusProviding` returns nil, so no last-scan check exists and unknown stays
    /// nil). Detections that could not be attributed to a file still count as unresolved: they are real until proven
    /// otherwise.
    public static func scanStatus(from summary: ScanSummary?, unresolvedFindings: Int) -> ScanStatus {
        ScanStatus(
            lastScan: summary.flatMap { lastScanDate(summary: $0) },
            nextScan: nil,
            unresolvedFindings: max(0, unresolvedFindings) + (summary?.unattributedDetections ?? 0)
        )
    }
}
