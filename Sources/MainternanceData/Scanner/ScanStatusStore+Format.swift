import Foundation
import MainternanceDomain

/// The JSON shapes of the status file (see `ScanStatusStore` for the format).
struct StatusFile: Codable {
    var version: Int
    var findings: [StoredFinding]
    /// Decoded leniently: a damaged record loses the summary, not the findings.
    var lastScan: Lenient<StoredSummary>?
    /// Set when the last-scan record was damaged and had to be dropped on a later write.
    var summaryUnreadable: Bool?
    /// An earlier file could not be read and was moved aside; cleared by the next completed scan.
    var earlierResultsUnreadable: Bool?
    var scanDidNotFinish: Bool?
    var unattributedFromIncompleteScan: Int?
    var unattributedScope: StoredScope?
    var resolvedByQuarantine: [Lenient<StoredLink>]?
}

/// Decodes to nil instead of failing when one element is damaged, so one bad entry cannot take the list with it.
struct Lenient<Value: Codable>: Codable {
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

struct StoredScope: Codable {
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

struct StoredLink: Codable {
    var recordID: String
    var finding: StoredFinding
}

struct StoredFinding: Codable {
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

struct StoredSummary: Codable {
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
    /// Optional: records written before these counts existed read as zero.
    var tooLarge: Int?
    var unreadableFolders: Int?

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
        tooLarge = summary.tooLarge
        unreadableFolders = summary.unreadableFolders
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
            permissionDenied: permissionDenied ?? 0, unattributedDetections: unattributedDetections ?? 0,
            tooLarge: tooLarge ?? 0, unreadableFolders: unreadableFolders ?? 0
        )
    }
}
