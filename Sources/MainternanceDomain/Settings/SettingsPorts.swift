import Foundation

/// What one `PreferencesStoring.update` produced: the values after the change, and whether they reached the disk.
/// `saved` is false when the file could not be read, a damaged file could not be moved aside, or the write itself
/// failed (a full disk, a folder that cannot be written): the values then exist only in memory.
public struct PreferencesUpdate: Sendable, Equatable {
    public let preferences: AppPreferences
    public let saved: Bool

    public init(preferences: AppPreferences, saved: Bool) {
        self.preferences = preferences
        self.saved = saved
    }
}

/// Saves and loads the Settings. `load` never fails: a missing or damaged file gives defaults.
public protocol PreferencesStoring: Sendable {
    func load() async -> AppPreferences
    /// Replaces every saved value and says whether they reached the disk. Two writers (Settings and the weekly
    /// scheduler) must use `update` instead, or one can write back values the other changed meanwhile.
    @discardableResult
    func save(_ preferences: AppPreferences) async -> Bool
    /// Reads, changes and writes the saved values as one step that no other `update` or `save` can interleave
    /// with, following `AppPreferences.updated(now:_:)` (a recorded run is never moved back). Returns the values
    /// after the change and whether they were written.
    @discardableResult
    func update(_ change: @Sendable (inout AppPreferences) -> Void) async -> PreferencesUpdate
}

/// The real state of "Launch at login", as macOS reports it.
public enum LoginItemStatus: Sendable, Equatable {
    case enabled
    case disabled
    /// Registered, but the owner must allow it in System Settings > General > Login Items.
    case requiresApproval
    /// Not possible here (for example the app is not running from a bundle).
    case unavailable
}

public protocol LoginItemControlling: Sendable {
    func status() -> LoginItemStatus
    /// Asks for the change and returns the status read back afterwards, which may differ from the request.
    func setEnabled(_ enabled: Bool) throws -> LoginItemStatus
}

/// Whether the app may show notifications.
public enum NotificationAuthorization: Sendable, Equatable {
    case notDetermined
    case allowed
    case denied
    /// Notifications cannot be used here (for example the app is not running from a bundle).
    case unavailable
}

/// One notification. Posting a notice with the same `id` replaces the earlier one.
public struct UserNotice: Sendable, Equatable {
    public let id: String
    public let title: String
    public let body: String

    public init(id: String, title: String, body: String) {
        self.id = id
        self.title = title
        self.body = body
    }
}

public protocol NotificationPosting: Sendable {
    func authorization() async -> NotificationAuthorization
    /// Asks the owner once (macOS shows the prompt only while `notDetermined`) and returns the result.
    func requestAuthorization() async -> NotificationAuthorization
    /// Posts the notice; does nothing when notifications are not allowed.
    func post(_ notice: UserNotice) async
}
