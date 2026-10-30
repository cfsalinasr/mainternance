import Foundation

public struct QuarantineRecord: Sendable, Equatable, Identifiable, Codable {
    public let id: UUID
    public let originalPath: String
    public let quarantinedAt: Date
    public let signature: String
    public let sha256: String
    public let size: Int64

    public init(id: UUID, originalPath: String, quarantinedAt: Date, signature: String, sha256: String, size: Int64) {
        self.id = id
        self.originalPath = originalPath
        self.quarantinedAt = quarantinedAt
        self.signature = signature
        self.sha256 = sha256
        self.size = size
    }
}

public enum QuarantineError: Error, Sendable, Equatable {
    case protectedPath
    case notRegularFile
    case missing
    case changedSinceScan
    case restoreTargetMissing
    case alreadyQuarantined
    case ioFailure(String)
}

/// Port for the quarantine store. Quarantine moves a file; nothing is ever deleted.
public protocol QuarantineStoring: Sendable {
    func quarantine(path: String, signature: String) async throws -> QuarantineRecord
    /// Restores the file and returns the path it was restored to.
    func restore(_ id: UUID) async throws -> String
    func records() async -> [QuarantineRecord]
}
