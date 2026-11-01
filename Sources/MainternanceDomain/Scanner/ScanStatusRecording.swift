import Foundation

/// What the scanner remembers between launches: the last completed scan (nil when none ever completed) and the
/// findings that are still unresolved (not quarantined).
public struct RecordedScanStatus: Sendable, Equatable {
    public let summary: ScanSummary?
    public let findings: [ScanFinding]

    public init(summary: ScanSummary?, findings: [ScanFinding]) {
        self.summary = summary
        self.findings = findings
    }
}

/// Port the scanner screen uses to remember what it knows, so Home can show it and the next launch can list the
/// findings again. Implemented in the Data layer, which also provides the matching `ScanStatusProviding`.
public protocol ScanStatusRecording: Sendable {
    /// Records a scan that ended, with the findings still unresolved after it. A cancelled scan never becomes the
    /// "last scan" (the previous one is kept), but the findings it already reported are real and are kept.
    func recordScan(_ summary: ScanSummary, findings: [ScanFinding]) async
    /// Replaces the unresolved findings (a file was quarantined or restored, or a scan failed after reporting
    /// findings). The last scan itself is untouched.
    func updateFindings(_ findings: [ScanFinding]) async
    /// Nil when nothing was recorded yet or the record is unreadable.
    func load() async -> RecordedScanStatus?
}
