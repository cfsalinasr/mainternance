import Foundation

/// Why a startup item could not be switched.
public enum StartupError: Error, Equatable, LocalizedError {
    /// Not one of the owner's own agents: read-only here by design.
    case notAllowed
    /// The item's file could not be read, so nothing about it is trusted enough to switch.
    case unreadable
    /// The label is missing or not safe to pass to `launchctl`.
    case invalidLabel
    /// `launchctl` refused; carries its reason.
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .notAllowed:
            "Only your own agents can be switched here. "
                + "This one is installed for all users: change it in the app that installed it."
        case .unreadable:
            "This item's file could not be read, so nothing was changed."
        case .invalidLabel:
            "This item's label cannot be passed to launchctl safely, so nothing was changed."
        case let .failed(reason):
            "macOS could not change it: \(reason)"
        }
    }
}

/// Lists the launch agents and daemons. Never fails: what could not be read is marked in the snapshot.
public protocol StartupListing: Sendable {
    func list() async -> StartupSnapshot
}

/// Switches one of the owner's own agents off or on (reversible; it takes effect at the next login).
public protocol StartupControlling: Sendable {
    /// Throws `StartupError`.
    func setEnabled(_ item: StartupItem, _ enabled: Bool) async throws
}

/// Remembers which items the owner has seen.
public protocol StartupReviewing: Sendable {
    /// Makes the items in `snapshot` the new baseline: none of them counts as new afterwards. What was known
    /// before for a folder the snapshot could not open is kept. False when the baseline could not be saved
    /// (nothing changed).
    func markReviewed(_ snapshot: StartupSnapshot) async -> Bool
}
