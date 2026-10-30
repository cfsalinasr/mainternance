import Foundation

/// State of the scanning engine (ClamAV) as the UI should describe it.
public enum EngineStatus: Sendable, Equatable {
    case homebrewMissing
    case notInstalled
    case installing(stage: String)
    case downloadingDefinitions
    case ready(definitionsAge: TimeInterval?)
    case updateNeeded(definitionsAge: TimeInterval?)
    case failed(message: String)

    /// Definitions older than this many seconds (7 days) need an update.
    public static let maximumDefinitionsAge: TimeInterval = 7 * 24 * 60 * 60

    /// Pure rule. A definitions date in the future (clock skew) counts as age 0.
    public static func status(
        engineInstalled: Bool,
        homebrewAvailable: Bool,
        definitionsDate: Date?,
        now: Date
    ) -> EngineStatus {
        guard engineInstalled else { return homebrewAvailable ? .notInstalled : .homebrewMissing }
        guard let definitionsDate else { return .updateNeeded(definitionsAge: nil) }
        let age = max(0, now.timeIntervalSince(definitionsDate))
        return age > maximumDefinitionsAge ? .updateNeeded(definitionsAge: age) : .ready(definitionsAge: age)
    }
}

public enum ScanScope: Sendable, Equatable {
    case quick
    case full
    case custom(URL)
}

public struct ScanFinding: Sendable, Equatable, Identifiable {
    public let id: UUID
    public let path: String
    public let signature: String
    public let foundAt: Date

    public init(id: UUID, path: String, signature: String, foundAt: Date) {
        self.id = id
        self.path = path
        self.signature = signature
        self.foundAt = foundAt
    }
}

public struct ScanSummary: Sendable, Equatable {
    public let scope: ScanScope
    public let scanned: Int
    /// Files that could not be read (permission errors included). They were NOT scanned and are never "clean".
    public let unreadable: Int
    /// How many of the `unreadable` files failed on permissions (the usual cause is a missing Full Disk Access).
    public let permissionDenied: Int
    public let findings: Int
    public let startedAt: Date
    public let endedAt: Date
    public let cancelled: Bool
    public let definitionsDate: Date?
    /// Detections the engine reported that could NOT be attributed to a file (for example a file name with a
    /// newline splits the engine's output line, or the reported path is not below the scanned folders). They are
    /// real detections, only without a usable path, so a scan with `unattributedDetections > 0` is never clean.
    /// Task 7 must show "N detection(s) could not be attributed to a file (unusual file names). The scan is not
    /// clean." and count them as unresolved findings for the health status. The count is also appended to the
    /// message of a `.failed` that ends a scan after findings.
    public let unattributedDetections: Int

    public init(
        scope: ScanScope, scanned: Int, unreadable: Int, findings: Int,
        startedAt: Date, endedAt: Date, cancelled: Bool, definitionsDate: Date?, permissionDenied: Int = 0,
        unattributedDetections: Int = 0
    ) {
        self.scope = scope
        self.scanned = scanned
        self.unreadable = unreadable
        self.permissionDenied = min(max(0, permissionDenied), max(0, unreadable))
        self.findings = findings
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.cancelled = cancelled
        self.definitionsDate = definitionsDate
        self.unattributedDetections = max(0, unattributedDetections)
    }

    /// True only when the scan ran to the end and found nothing, attributed or not. A clean scan can still be
    /// PARTIAL: see `isComplete`.
    public var isClean: Bool {
        findings == 0 && unattributedDetections == 0 && !cancelled
    }

    /// True when the scan was not cancelled and every file could be read. `unreadable > 0` makes it a PARTIAL scan
    /// (those files were not scanned and are never reported as clean).
    public var isComplete: Bool {
        unreadable == 0 && !cancelled
    }
}

/// Result of re-checking one file with the engine, before anything is done to it (for example quarantine).
public enum VerifyResult: Sendable, Equatable {
    /// The engine flagged this very file again, with this signature.
    case confirmed(signature: String)
    /// The engine scanned the file and found nothing.
    case clean
    case failed(message: String)
}

/// Events of one scan.
///
/// `.found` events delivered before a `.failed` are REAL findings: the consumer must keep them. A scan can fail
/// after it already reported files (for example a fatal error late in the run), and those files are still flagged.
public enum ScanEvent: Sendable, Equatable {
    case started(scope: ScanScope)
    case progress(scanned: Int, current: String)
    case found(ScanFinding)
    case finished(ScanSummary)
    case failed(message: String)
}

public enum InstallEvent: Sendable, Equatable {
    case stage(String)
    /// nil is indeterminate. For definitions updates the value restarts per database file: 1 is not completion.
    case progress(Double?)
    case finished
    case failed(message: String)
}
