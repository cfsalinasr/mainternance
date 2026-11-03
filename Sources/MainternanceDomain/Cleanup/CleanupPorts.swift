import Foundation

/// Measures what could be cleaned. Never fails: a folder that cannot be read is listed in `unreadable`, a part of an
/// entry that cannot be read makes its size a lower bound. Cancelling stops early with lower-bound sizes.
public protocol CleanupScanning: Sendable {
    func measure() async -> CleanupMeasurement
}

/// Moves measured entries to the Trash (never a permanent delete), one at a time: an entry that cannot be moved is
/// reported with its reason and the rest continue.
public protocol CleanupMoving: Sendable {
    func moveToTrash(_ entries: [CleanupEntry]) async -> CleanupOutcome
}
