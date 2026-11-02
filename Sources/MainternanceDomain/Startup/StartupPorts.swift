import Foundation

/// Why a startup item could not be switched.
public enum StartupError: Error, Equatable, LocalizedError {
    /// Not one of the owner's own agents (or its file could not be read): it needs an administrator.
    case notAllowed
    /// The label is missing or not safe to pass to `launchctl`.
    case invalidLabel
    /// `launchctl` refused; carries its reason.
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .notAllowed:
            "Only your own agents can be switched here. This one needs an administrator: "
                + "change it in the app that installed it."
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
    /// Makes `labels` (the items' `reviewKey`s) the new baseline: nothing in it counts as new afterwards.
    func markReviewed(_ labels: [String]) async
}
