import Foundation

/// The fixed places Cleanup measures, all under the owner's home folder.
public enum CleanupKind: String, Sendable, CaseIterable {
    /// Each direct child of `~/Library/Caches`.
    case caches
    /// Each direct child of `~/Library/Logs`.
    case logs
    /// Disk images and installer packages in `~/Downloads` not changed or added for more than 30 days.
    case installers
    /// Each direct child of `~/Library/Developer/Xcode/DerivedData`.
    case developer

    /// Whether a measuring ticks this category's entries. Old installers never start ticked: an installer can be
    /// the only copy of something the owner kept on purpose, so it moves only once they tick it themselves.
    public var isSelectedByDefault: Bool {
        self != .installers
    }
}

/// One direct child of a Cleanup folder: the unit that is reviewed and moved to the Trash.
///
/// `id` is the absolute path exactly as found on disk; `name` is its last component, also exactly as found (it can
/// hold spaces, line breaks or bidi characters). Show `displayName`, never `name`.
public struct CleanupEntry: Sendable, Equatable, Identifiable {
    /// What the entry is on disk, read without following links.
    public enum ItemType: Sendable, Equatable {
        case file, directory, symbolicLink
    }

    /// Which item on disk it is (device and inode, read without following links): a different item put at the same
    /// path has a different identity.
    public struct Identity: Sendable, Hashable {
        public let device: Int32
        public let inode: UInt64

        public init(device: Int32, inode: UInt64) {
            self.device = device
            self.inode = inode
        }
    }

    public let id: String
    public let name: String
    /// Allocated bytes, without following links or crossing to another volume.
    public let bytes: Int64
    /// True when part of the entry could not be read (or measuring stopped early): the size is at least `bytes`.
    public let isLowerBound: Bool
    public let type: ItemType
    public let modified: Date?
    /// The item measured; nil when not known. The mover refuses an entry whose identity changed.
    public let identity: Identity?

    public init(
        path: String, bytes: Int64, isLowerBound: Bool, type: ItemType, modified: Date?, identity: Identity? = nil
    ) {
        id = path
        name = (path as NSString).lastPathComponent
        self.bytes = max(bytes, 0)
        self.isLowerBound = isLowerBound
        self.type = type
        self.modified = modified
        self.identity = identity
    }

    public var isDirectory: Bool {
        type == .directory
    }

    /// The name as shown: no control, bidi or zero-width characters.
    public var displayName: String {
        DisplayText.clean(name)
    }
}

/// The entries found in one Cleanup folder.
public struct CleanupCategory: Sendable, Equatable, Identifiable {
    public let kind: CleanupKind
    public var entries: [CleanupEntry]

    public init(kind: CleanupKind, entries: [CleanupEntry]) {
        self.kind = kind
        self.entries = entries
    }

    public var id: String {
        kind.rawValue
    }

    public var bytes: Int64 {
        CleanupMath.sum(entries.map(\.bytes))
    }

    public var isLowerBound: Bool {
        entries.contains(where: \.isLowerBound)
    }
}

/// One measuring of every Cleanup folder.
public struct CleanupMeasurement: Sendable, Equatable {
    /// In `CleanupKind` order; a folder that does not exist has no category.
    public var categories: [CleanupCategory]
    public let measuredAt: Date
    /// Folders that exist but could not be opened (or are a symbolic link, which is never followed).
    public let unreadable: [CleanupKind]

    public init(categories: [CleanupCategory], measuredAt: Date, unreadable: [CleanupKind] = []) {
        self.categories = categories
        self.measuredAt = measuredAt
        self.unreadable = unreadable
    }

    public var totalBytes: Int64 {
        CleanupMath.sum(categories.map(\.bytes))
    }

    public var isLowerBound: Bool {
        categories.contains(where: \.isLowerBound)
    }
}

/// An entry that was not moved, and why in plain words.
public struct CleanupFailure: Sendable, Equatable {
    public let entry: CleanupEntry
    public let reason: String

    public init(entry: CleanupEntry, reason: String) {
        self.entry = entry
        self.reason = reason
    }
}

/// What a move to the Trash really did. Only `moved` entries count as freed (once the owner empties the Trash).
public struct CleanupOutcome: Sendable, Equatable {
    public let moved: [CleanupEntry]
    public let failed: [CleanupFailure]

    public init(moved: [CleanupEntry], failed: [CleanupFailure]) {
        self.moved = moved
        self.failed = failed
    }

    public var movedBytes: Int64 {
        CleanupMath.sum(moved.map(\.bytes))
    }
}

/// Why an entry was not moved.
public enum CleanupRefusal: Error, Equatable, Sendable {
    /// Not a direct child of a Cleanup folder (or no longer matches its folder's rule).
    case notInCleanupFolder
    /// Inside a protected place (system folders, the home folder itself, the app).
    case protected
    /// A link that points into a protected place. Only the link would move, but it is left alone all the same.
    case protectedLink
    /// Nothing is at the path any more.
    case vanished
    /// A file became a folder, a folder became a link, another item took its place, or its folder was replaced.
    case changed
    /// A folder on another disk or volume (mounted inside a Cleanup folder): never entered or moved.
    case otherVolume
    /// It could not be checked again before moving, so it was left alone.
    case unreadable
    /// macOS refused the move; carries its reason.
    case trashFailed(String)

    public var text: String {
        switch self {
        case .notInCleanupFolder: "It is not in one of the folders Cleanup looks at."
        case .protected: "It is in a protected place."
        case .protectedLink: "This is a link to a protected place."
        case .vanished: "It is no longer there."
        case .changed: "It changed since it was measured."
        case .otherVolume: "It is on another disk, so Cleanup leaves it alone."
        case .unreadable: "It could not be checked, so it was left where it is."
        case let .trashFailed(reason): "macOS could not move it to the Trash: \(reason)"
        }
    }
}

public enum CleanupMath {
    /// Adds non-negative byte counts, stopping at `Int64.max` instead of overflowing.
    public static func sum(_ values: [Int64]) -> Int64 {
        values.reduce(0) { total, value in
            let added = total.addingReportingOverflow(max(value, 0))
            return added.overflow ? .max : added.partialValue
        }
    }
}
