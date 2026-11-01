import Foundation
import MainternanceDomain

/// Persists the last completed scan and the unresolved findings as JSON in one file (mode `0o600`), so Home can
/// show the scanner's state without the Scanner screen being open and the next launch can list the findings again.
///
/// Format (version 1): dates are seconds since 1970, `scope` is `quick`, `full` or `custom` (with `customPath`),
/// `findings` lists the unresolved findings. `lastScan` is absent when no scan ever completed. A missing,
/// unreadable or unknown file reads as nil; the next write replaces it. A cancelled scan is never stored as the
/// last scan (the previous one stays), but the findings it reported are kept. The previous scan's
/// unattributed-detection count stays with the previous scan.
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
        return RecordedScanStatus(summary: stored.lastScan?.summary, findings: findings)
    }

    public func recordScan(_ summary: ScanSummary, findings: [ScanFinding]) {
        let last = summary.cancelled ? load()?.summary : summary
        write(RecordedScanStatus(summary: last, findings: findings))
    }

    public func updateFindings(_ findings: [ScanFinding]) {
        write(RecordedScanStatus(summary: load()?.summary, findings: findings))
    }

    private func write(_ status: RecordedScanStatus) {
        let stored = Stored(
            version: Self.currentVersion,
            findings: status.findings.map(StoredFinding.init),
            lastScan: status.summary.map(StoredSummary.init)
        )
        guard let data = try? JSONEncoder().encode(stored) else { return }
        let manager = FileManager.default
        try? manager.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        guard (try? data.write(to: file, options: .atomic)) != nil else { return }
        try? manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
}

private struct Stored: Codable {
    var version: Int
    var findings: [StoredFinding]
    var lastScan: StoredSummary?
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
