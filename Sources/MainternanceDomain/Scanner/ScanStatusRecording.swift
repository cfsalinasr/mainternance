import Foundation

/// What the scanner remembers between launches.
public struct RecordedScanStatus: Sendable, Equatable {
    /// The last COMPLETED scan; nil when none ever completed, or when its record was damaged (see
    /// `summaryUnreadable`).
    public let summary: ScanSummary?
    /// True when a last-scan record existed but could not be read. The findings are still trusted (they are read
    /// separately); the date of their detection stands in for "when a scan last ran" so Home never says
    /// "Never scanned" next to listed findings.
    public let summaryUnreadable: Bool
    /// Findings that are still unresolved (not quarantined).
    public let findings: [ScanFinding]
    /// Detections of a cancelled or failed scan that could not be attributed to a file. They stay counted as
    /// unresolved until the next COMPLETED scan replaces this number.
    public let unattributedFromIncompleteScan: Int
    /// The scope of the scan that left `unattributedFromIncompleteScan` behind (the broader one when several did).
    /// Only a completed scan of that scope, or a full scan, with no unattributed detections of its own resets it.
    public let unattributedScope: ScanScope?
    /// A scan was started and neither completed, cancelled nor failed on record: the app was quit or crashed
    /// during it. Home says "Last scan did not finish" until a scan ends and records its own state.
    public let scanDidNotFinish: Bool
    /// An earlier status file could not be read and was moved aside; until a scan completes, nothing may be claimed
    /// about what that file held.
    public let earlierResultsUnreadable: Bool
    /// Findings that were quarantined, by quarantine record id, so a restore can put them back in the list.
    public let resolvedByQuarantine: [UUID: ScanFinding]

    public init(
        summary: ScanSummary?, summaryUnreadable: Bool = false, findings: [ScanFinding],
        unattributedFromIncompleteScan: Int = 0, unattributedScope: ScanScope? = nil, scanDidNotFinish: Bool = false,
        earlierResultsUnreadable: Bool = false, resolvedByQuarantine: [UUID: ScanFinding] = [:]
    ) {
        self.earlierResultsUnreadable = earlierResultsUnreadable
        self.summary = summary
        self.summaryUnreadable = summaryUnreadable
        self.findings = findings
        self.unattributedFromIncompleteScan = max(0, unattributedFromIncompleteScan)
        self.unattributedScope = unattributedScope
        self.scanDidNotFinish = scanDidNotFinish
        self.resolvedByQuarantine = resolvedByQuarantine
    }
}

/// The parts of the scanner's memory that change with every scan or quarantine action.
public struct ScanMemory: Sendable, Equatable {
    public var findings: [ScanFinding]
    public var unattributedFromIncompleteScan: Int
    public var unattributedScope: ScanScope?
    public var scanDidNotFinish: Bool
    public var resolvedByQuarantine: [UUID: ScanFinding]

    public init(
        findings: [ScanFinding], unattributedFromIncompleteScan: Int = 0, unattributedScope: ScanScope? = nil,
        scanDidNotFinish: Bool = false, resolvedByQuarantine: [UUID: ScanFinding] = [:]
    ) {
        self.findings = findings
        self.unattributedFromIncompleteScan = unattributedFromIncompleteScan
        self.unattributedScope = unattributedScope
        self.scanDidNotFinish = scanDidNotFinish
        self.resolvedByQuarantine = resolvedByQuarantine
    }
}

/// Port the scanner screen uses to remember what it knows, so Home can show it and the next launch can list the
/// findings again. Implemented in the Data layer, which also provides the matching `ScanStatusProviding`.
public protocol ScanStatusRecording: Sendable {
    /// Records a scan that ended. A cancelled scan never becomes the "last scan" (the previous one is kept); the
    /// memory (findings and counts) is always stored.
    func recordScan(_ summary: ScanSummary, memory: ScanMemory) async
    /// Stores new memory and leaves the last scan untouched (a scan failed, or a file was quarantined or restored).
    func remember(_ memory: ScanMemory) async
    /// Like `recordScan`/`remember`, for the many small updates during a scan (one per detection): the first one is
    /// written at once, later ones are coalesced (at most one write per second) and always written by the next
    /// `recordScan`/`remember`, by `flush()` and by the quit hook, so no detection is lost.
    func rememberProgress(_ memory: ScanMemory) async
    /// Writes anything still pending.
    func flush() async
    /// Nil when nothing was recorded yet or the record is unreadable.
    func load() async -> RecordedScanStatus?
    /// Tells "nothing saved" from "saved but unreadable".
    func loadState() async -> ScanStatusLoad
}

/// What loading the saved status found.
public enum ScanStatusLoad: Sendable, Equatable {
    case nothingSaved
    case saved(RecordedScanStatus)
    /// A file is there but cannot be read: nothing may be claimed (not "never scanned", not "no findings").
    case unreadable
}
