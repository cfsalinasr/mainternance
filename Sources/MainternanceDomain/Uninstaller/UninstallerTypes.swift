import Foundation

/// An app found in an Applications folder. Read-only facts; nothing about it is measured here.
///
/// `id` is the absolute path of the `.app` folder exactly as found on disk. `name`, and `bundleID` and `version` when
/// present, come from the app's own `Info.plist` and are untrusted: show `displayName`, never `name`.
public struct InstalledApp: Sendable, Equatable, Identifiable {
    public let id: String
    public let name: String
    /// nil when the app has no readable, well-formed identifier.
    public let bundleID: String?
    public let version: String?
    /// Which folder on disk the app is (read without following links); the mover refuses a swapped app.
    public let identity: CleanupEntry.Identity?

    public init(
        path: String, name: String, bundleID: String?, version: String?, identity: CleanupEntry.Identity? = nil
    ) {
        id = path
        self.name = name
        self.bundleID = bundleID
        self.version = version
        self.identity = identity
    }

    public var displayName: String {
        let cleaned = DisplayText.clean(name)
        return cleaned.isEmpty ? DisplayText.clean((id as NSString).lastPathComponent) : cleaned
    }
}

/// How sure we are that a leftover belongs to the app.
public enum LeftoverMatch: Sendable, Equatable {
    /// Named exactly with the app's bundle identifier.
    case identifier
    /// Named like the app, nothing more: it may belong to something else.
    case nameOnly
    /// A launch agent of the app: it starts something at login.
    case launchAgent

    /// Only an identifier match starts ticked.
    public var isSelectedByDefault: Bool {
        self == .identifier
    }
}

/// One item the app left in the owner's `~/Library`.
///
/// `id` is the absolute path as found; show `displayName`.
public struct Leftover: Sendable, Equatable, Identifiable {
    public let id: String
    public let name: String
    /// The `~/Library` folder it is in, such as "Caches".
    public let location: String
    public let match: LeftoverMatch
    /// Allocated bytes, without following links or crossing volumes.
    public let bytes: Int64
    public let isLowerBound: Bool
    public let type: CleanupEntry.ItemType
    public let identity: CleanupEntry.Identity?

    public init(
        path: String, location: String, match: LeftoverMatch, bytes: Int64, isLowerBound: Bool,
        type: CleanupEntry.ItemType, identity: CleanupEntry.Identity? = nil
    ) {
        id = path
        name = (path as NSString).lastPathComponent
        self.location = location
        self.match = match
        self.bytes = max(bytes, 0)
        self.isLowerBound = isLowerBound
        self.type = type
        self.identity = identity
    }

    public var displayName: String {
        DisplayText.clean(name)
    }
}

/// A selected app with its measured size and its leftovers (largest first).
public struct AppDetails: Sendable, Equatable {
    public let app: InstalledApp
    public let appBytes: Int64
    public let appIsLowerBound: Bool
    public let leftovers: [Leftover]

    public init(app: InstalledApp, appBytes: Int64, appIsLowerBound: Bool, leftovers: [Leftover]) {
        self.app = app
        self.appBytes = max(appBytes, 0)
        self.appIsLowerBound = appIsLowerBound
        self.leftovers = leftovers
    }
}
