import Foundation

/// One quarantined file, as listed in the quarantine manifest.
public struct QuarantineRecord: Sendable, Equatable, Identifiable, Codable {
    public let id: UUID
    /// Absolute path the file had when it was quarantined; restore puts it back here.
    public let originalPath: String
    public let quarantinedAt: Date
    /// Name of the detection (signature) that caused the quarantine.
    public let signature: String
    /// Lowercase hex SHA-256 of the content at quarantine time.
    public let sha256: String
    public let size: Int64
    /// POSIX permission bits (for example `0o755`) the file had before quarantine; restored with the file.
    public let originalPermissions: Int

    public init(
        id: UUID, originalPath: String, quarantinedAt: Date, signature: String, sha256: String, size: Int64,
        originalPermissions: Int
    ) {
        self.id = id
        self.originalPath = originalPath
        self.quarantinedAt = quarantinedAt
        self.signature = signature
        self.sha256 = sha256
        self.size = size
        self.originalPermissions = originalPermissions
    }
}

public enum QuarantineError: Error, Sendable, Equatable {
    /// The path is a system, home, app or quarantine location the app refuses to move.
    case protectedPath
    /// The path is a symlink, a directory or another special file; only regular files are quarantined.
    case notRegularFile
    /// There is no such file (or no such record to restore, or it was already restored).
    case missing
    /// The file no longer matches what the scan saw.
    case changedSinceScan
    /// The folder the file came from no longer exists, so nothing was restored.
    case restoreTargetMissing
    /// A file system operation failed; the message is the system's description. The original file is left in place.
    case ioFailure(String)
}

/// Port for the quarantine store. Quarantine moves a file; the store has no API that deletes anything.
public protocol QuarantineStoring: Sendable {
    func quarantine(path: String, signature: String) async throws -> QuarantineRecord
    /// Restores the file and returns the path it was restored to.
    func restore(_ id: UUID) async throws -> String
    /// Items that are really in quarantine (the vault holds them and they are no longer at their old path).
    func records() async -> [QuarantineRecord]
    /// Records whose copy is in the vault but whose original ALSO still sits at its old path (an interrupted copy
    /// across volumes). They are NOT contained: the UI must say the file could not be moved.
    func stillInPlace() async -> [QuarantineRecord]
    /// Files in the vault that no record describes. They are never touched; the UI only mentions them.
    func unclaimedFiles() async -> [String]
}
