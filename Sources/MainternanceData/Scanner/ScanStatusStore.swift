import Foundation
import MainternanceDomain

/// Persists what the scanner remembers as JSON in one file (mode `0o600`), so Home can show the scanner's state
/// without the Scanner screen being open and the next launch can list the findings again.
///
/// Format (version 1): dates are seconds since 1970; a scope is `quick`, `full` or `custom` (with `customPath`).
/// - `findings`: the unresolved findings. They are what matters for safety, so one damaged entry makes the whole
///   file unreadable (nil) rather than half-trusted.
/// - `lastScan`: the last COMPLETED scan, absent when none ever completed. A cancelled scan never replaces it. A
///   damaged `lastScan` only loses the summary (`summaryUnreadable`); the findings stay.
/// - `scanDidNotFinish`: a scan started and has not recorded its end (quit or crash), until one does.
/// - `unattributedFromIncompleteScan` and `unattributedScope`: detections of a cancelled or failed scan that could
///   not be attributed to a file, and the scope of that scan.
/// - `resolvedByQuarantine`: quarantine record id to the finding it resolved, so Restore can put it back. A damaged
///   entry is skipped, the rest stays.
///
/// A file that exists but cannot be read is never overwritten: the next save moves it aside as
/// `<name>.corrupt-<uuid>.json` first (like the quarantine store does with its manifest).
public actor ScanStatusStore: ScanStatusRecording {
    private static let currentVersion = 1

    private let file: URL

    public init(file: URL) {
        self.file = file
    }

    /// The default location: `<Application Support>/Mainternance/scan-status.json`.
    public static func defaultFile(paths: ClamAVPaths = ClamAVPaths()) -> URL {
        paths.supportDirectory.appendingPathComponent("scan-status.json", isDirectory: false)
    }

    public func load() -> RecordedScanStatus? {
        guard let data = try? Data(contentsOf: file),
              let stored = try? JSONDecoder().decode(Stored.self, from: data),
              stored.version == Self.currentVersion
        else {
            return nil
        }
        var findings: [ScanFinding] = []
        for item in stored.findings {
            guard let finding = item.finding else { return nil }
            findings.append(finding)
        }
        var links: [UUID: ScanFinding] = [:]
        for entry in (stored.resolvedByQuarantine ?? []).compactMap(\.value) {
            if let id = UUID(uuidString: entry.recordID), let finding = entry.finding.finding {
                links[id] = finding
            }
        }
        let summary = stored.lastScan?.summary
        return RecordedScanStatus(
            summary: summary,
            summaryUnreadable: stored.summaryUnreadable == true || (stored.lastScan != nil && summary == nil),
            findings: findings,
            unattributedFromIncompleteScan: stored.unattributedFromIncompleteScan ?? 0,
            unattributedScope: stored.unattributedScope?.scope,
            scanDidNotFinish: stored.scanDidNotFinish == true,
            resolvedByQuarantine: links
        )
    }

    public func recordScan(_ summary: ScanSummary, memory: ScanMemory) {
        let previous = load()
        let last = summary.cancelled ? previous?.summary : summary
        write(last, unreadable: summary.cancelled && previous?.summaryUnreadable == true, memory)
    }

    public func remember(_ memory: ScanMemory) {
        let previous = load()
        write(previous?.summary, unreadable: previous?.summaryUnreadable == true, memory)
    }

    private func write(_ summary: ScanSummary?, unreadable: Bool, _ memory: ScanMemory) {
        let stored = Stored(
            version: Self.currentVersion,
            findings: memory.findings.map(StoredFinding.init),
            lastScan: summary.map(StoredSummary.init),
            summaryUnreadable: unreadable && summary == nil ? true : nil,
            scanDidNotFinish: memory.scanDidNotFinish ? true : nil,
            unattributedFromIncompleteScan: max(0, memory.unattributedFromIncompleteScan),
            unattributedScope: memory.unattributedFromIncompleteScan > 0
                ? memory.unattributedScope.map(StoredScope.init) : nil,
            resolvedByQuarantine: memory.resolvedByQuarantine.map {
                Lenient(StoredLink(recordID: $0.key.uuidString, finding: StoredFinding($0.value)))
            }.sorted { ($0.value?.recordID ?? "") < ($1.value?.recordID ?? "") }
        )
        guard let data = try? JSONEncoder().encode(stored) else { return }
        let manager = FileManager.default
        try? manager.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        keepUnreadableFileAside(manager)
        guard (try? data.write(to: file, options: .atomic)) != nil else { return }
        try? manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    /// A file that is there but cannot be read as a status is moved next to itself, never overwritten.
    private func keepUnreadableFileAside(_ manager: FileManager) {
        guard manager.fileExists(atPath: file.path), load() == nil else { return }
        let name = file.deletingPathExtension().lastPathComponent
        let aside = file.deletingLastPathComponent()
            .appendingPathComponent("\(name).corrupt-\(UUID().uuidString).json")
        try? manager.moveItem(at: file, to: aside)
    }
}

private struct Stored: Codable {
    var version: Int
    var findings: [StoredFinding]
    var lastScan: StoredSummary?
    /// Set when the last-scan record was damaged and had to be dropped on a later write.
    var summaryUnreadable: Bool?
    var scanDidNotFinish: Bool?
    var unattributedFromIncompleteScan: Int?
    var unattributedScope: StoredScope?
    var resolvedByQuarantine: [Lenient<StoredLink>]?
}

/// Decodes to nil instead of failing when one element is damaged, so one bad entry cannot take the list with it.
private struct Lenient<Value: Codable>: Codable {
    let value: Value?

    init(_ value: Value) {
        self.value = value
    }

    init(from decoder: Decoder) throws {
        value = try? Value(from: decoder)
    }

    func encode(to encoder: Encoder) throws {
        try value?.encode(to: encoder)
    }
}

private struct StoredScope: Codable {
    var kind: String
    var customPath: String?

    init(_ scope: ScanScope) {
        switch scope {
        case .quick: kind = "quick"
        case .full: kind = "full"
        case let .custom(url):
            kind = "custom"
            customPath = url.path
        }
    }

    /// Nil for an unknown kind or a custom scope without an absolute path.
    var scope: ScanScope? {
        switch kind {
        case "quick": .quick
        case "full": .full
        case "custom": customPath.flatMap { $0.hasPrefix("/") ? .custom(URL(fileURLWithPath: $0)) : nil }
        default: nil
        }
    }
}

private struct StoredLink: Codable {
    var recordID: String
    var finding: StoredFinding
}

private struct StoredFinding: Codable {
    var id: String
    var path: String
    var signature: String
    var foundAt: Double

    init(_ finding: ScanFinding) {
        id = finding.id.uuidString
        path = finding.path
        signature = finding.signature
        foundAt = finding.foundAt.timeIntervalSince1970
    }

    /// Nil for a damaged entry (bad id, relative path, non-finite date).
    var finding: ScanFinding? {
        guard let uuid = UUID(uuidString: id), path.hasPrefix("/"), foundAt.isFinite else { return nil }
        return ScanFinding(id: uuid, path: path, signature: signature, foundAt: Date(timeIntervalSince1970: foundAt))
    }
}

private struct StoredSummary: Codable {
    var scope: String
    var customPath: String?
    var scanned: Int
    var unreadable: Int
    var permissionDenied: Int?
    var findings: Int
    var startedAt: Double
    var endedAt: Double
    var cancelled: Bool
    var definitionsDate: Double?
    var unattributedDetections: Int?

    init(_ summary: ScanSummary) {
        switch summary.scope {
        case .quick:
            scope = "quick"
        case .full:
            scope = "full"
        case let .custom(url):
            scope = "custom"
            customPath = url.path
        }
        scanned = summary.scanned
        unreadable = summary.unreadable
        permissionDenied = summary.permissionDenied
        findings = summary.findings
        startedAt = summary.startedAt.timeIntervalSince1970
        endedAt = summary.endedAt.timeIntervalSince1970
        cancelled = summary.cancelled
        definitionsDate = summary.definitionsDate?.timeIntervalSince1970
        unattributedDetections = summary.unattributedDetections
    }

    /// Nil when the scope is unknown or a number is not finite: a damaged record is never half-trusted.
    var summary: ScanSummary? {
        let scanScope: ScanScope
        switch scope {
        case "quick": scanScope = .quick
        case "full": scanScope = .full
        case "custom":
            guard let customPath, customPath.hasPrefix("/") else { return nil }
            scanScope = .custom(URL(fileURLWithPath: customPath))
        default: return nil
        }
        guard startedAt.isFinite, endedAt.isFinite, definitionsDate?.isFinite ?? true else { return nil }
        return ScanSummary(
            scope: scanScope, scanned: scanned, unreadable: unreadable, findings: findings,
            startedAt: Date(timeIntervalSince1970: startedAt), endedAt: Date(timeIntervalSince1970: endedAt),
            cancelled: cancelled, definitionsDate: definitionsDate.map { Date(timeIntervalSince1970: $0) },
            permissionDenied: permissionDenied ?? 0, unattributedDetections: unattributedDetections ?? 0
        )
    }
}
