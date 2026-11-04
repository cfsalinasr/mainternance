import Foundation

/// What a file is, judged by its extension only (never by opening it).
public enum FileKind: String, Sendable, CaseIterable {
    case document, image, video, audio, archive, code, other

    /// The one extension table. Lowercased extensions, without the dot.
    private static let table: [String: FileKind] = {
        let groups: [(FileKind, [String])] = [
            (.document, [
                "pdf", "doc", "docx", "txt", "rtf", "rtfd", "md", "pages", "numbers", "key", "xls", "xlsx", "ppt",
                "pptx", "csv", "odt", "ods", "odp", "epub"
            ]),
            (.image, [
                "jpg", "jpeg", "png", "gif", "heic", "heif", "tif", "tiff", "bmp", "webp", "raw", "cr2", "cr3", "nef",
                "arw", "dng", "svg", "psd", "ico"
            ]),
            (.video, ["mov", "mp4", "m4v", "avi", "mkv", "wmv", "flv", "webm", "mpg", "mpeg", "3gp", "mts"]),
            (.audio, ["mp3", "m4a", "aac", "wav", "aif", "aiff", "flac", "ogg", "opus", "wma", "caf", "m4b"]),
            (
                .archive,
                ["zip", "tar", "gz", "tgz", "bz2", "xz", "7z", "rar", "dmg", "iso", "pkg", "xip", "sparseimage"]
            ),
            (.code, [
                "swift", "py", "js", "ts", "tsx", "jsx", "java", "kt", "c", "h", "cpp", "hpp", "m", "mm", "rb", "go",
                "rs", "php", "sh", "zsh", "html", "css", "json", "xml", "yml", "yaml", "sql", "ipynb"
            ])
        ]
        var table: [String: FileKind] = [:]
        for (kind, extensions) in groups {
            for item in extensions {
                table[item] = kind
            }
        }
        return table
    }()

    /// Every extension in the table for `kind`, lowercased, without the dot, sorted. Empty for `.other`.
    public static func extensions(for kind: FileKind) -> [String] {
        table.filter { $0.value == kind }.keys.sorted()
    }

    /// The kind for a file extension (without the dot), ignoring case; anything not in the table is `.other`.
    public static func kind(forExtension pathExtension: String) -> FileKind {
        table[pathExtension.lowercased()] ?? .other
    }
}

/// One plain file found on disk.
///
/// `id` is the absolute path exactly as found; `name` its last component, also exactly as found (it can hold spaces,
/// line breaks or bidi characters). Show `displayName` and `displayPath`, never `name` or `id`.
public struct FileItem: Sendable, Equatable, Identifiable {
    public let id: String
    public let name: String
    /// Allocated bytes.
    public let bytes: Int64
    public let modified: Date
    public let kind: FileKind
    /// The item found (device and inode, read without following links); nil when not known.
    public let identity: CleanupEntry.Identity?

    public init(path: String, bytes: Int64, modified: Date, identity: CleanupEntry.Identity?) {
        id = path
        name = (path as NSString).lastPathComponent
        self.bytes = max(bytes, 0)
        self.modified = modified
        kind = FileKind.kind(forExtension: (name as NSString).pathExtension)
        self.identity = identity
    }

    /// The name as shown: no control, bidi or zero-width characters.
    public var displayName: String {
        DisplayText.clean(name)
    }

    /// The path as shown: no control, bidi or zero-width characters. For showing only, never for disk access.
    public var displayPath: String {
        DisplayText.clean(id)
    }
}

/// One node of the disk-usage tree: a folder, a plain file, a package (counted as one item) or the "Other" node
/// that sums a folder's children beyond the ones kept. Immutable once built.
public final class DiskNode: Sendable, Identifiable, Equatable {
    /// The absolute path (for `Other`, its folder's path followed by a NUL and "other", which no path can be).
    public let id: String
    public let name: String
    /// Allocated bytes of everything below, without following links or crossing to another volume.
    public let bytes: Int64
    public let isOther: Bool
    public let isPackage: Bool
    /// Largest first; at most the scanner's limit plus one `Other` node, which comes last.
    public let children: [DiskNode]

    public init(id: String, name: String, bytes: Int64, isOther: Bool, isPackage: Bool, children: [DiskNode]) {
        self.id = id
        self.name = name
        self.bytes = max(bytes, 0)
        self.isOther = isOther
        self.isPackage = isPackage
        self.children = children
    }

    /// A plain folder with something inside: the treemap can open it.
    public var isDrillable: Bool {
        !isOther && !isPackage && !children.isEmpty
    }

    /// The name as shown: no control, bidi or zero-width characters.
    public var displayName: String {
        DisplayText.clean(name)
    }

    public static func == (lhs: DiskNode, rhs: DiskNode) -> Bool {
        lhs === rhs || (
            lhs.id == rhs.id && lhs.name == rhs.name && lhs.bytes == rhs.bytes && lhs.isOther == rhs.isOther
                && lhs.isPackage == rhs.isPackage && lhs.children == rhs.children
        )
    }
}

/// One finished walk of the home folder.
public struct DiskScanResult: Sendable, Equatable {
    /// Plain files at or above the threshold, largest first, capped (packages never appear).
    public let largest: [FileItem]
    public let tree: DiskNode
    /// Folders macOS would not list: totals are then "at least".
    public let unreadableFolders: Int
    /// True when the walk stopped early: everything is then a lower bound.
    public let wasCancelled: Bool

    public init(largest: [FileItem], tree: DiskNode, unreadableFolders: Int, wasCancelled: Bool) {
        self.largest = largest
        self.tree = tree
        self.unreadableFolders = max(unreadableFolders, 0)
        self.wasCancelled = wasCancelled
    }
}

/// What a disk scan reports while it runs.
public enum DiskScanUpdate: Sendable {
    case progress(scannedFiles: Int)
    case finished(DiskScanResult)
}

/// Plain files with exactly the same contents (same size, and the same SHA-256 of the whole file).
///
/// Hard links (two names for one item) are never a group: they are one file. APFS clones look like separate files
/// and can be a group, though they share disk space.
public struct DuplicateGroup: Sendable, Equatable, Identifiable {
    /// Stable for the same contents: the size and the content hash.
    public let id: String
    /// Allocated bytes of one copy (the smallest any copy takes, so the saving is never overstated).
    public let bytesEach: Int64
    /// At least two, sorted by path.
    public let files: [FileItem]

    public init(id: String, bytesEach: Int64, files: [FileItem]) {
        self.id = id
        self.bytesEach = max(bytesEach, 0)
        self.files = files.sorted { $0.id < $1.id }
    }

    /// What moving all but one copy would free: `bytesEach` times one less than the number of copies.
    public var reclaimableBytes: Int64 {
        let copies = Int64(max(files.count - 1, 0))
        let product = bytesEach.multipliedReportingOverflow(by: copies)
        return product.overflow ? .max : product.partialValue
    }
}

/// What a duplicate search reports while it runs.
public enum DuplicateUpdate: Sendable {
    /// What the search is doing now, in plain words.
    case phase(String)
    /// One group, confirmed by comparing whole files.
    case group(DuplicateGroup)
    /// The last update. When cancelled, the groups already sent are real but more may exist.
    case finished(unreadableFolders: Int, wasCancelled: Bool)
}

/// What the owner asked the file search for. Every filter that is set must hold.
public struct FileSearchQuery: Sendable, Equatable {
    /// Part of the file name; case and accents do not matter. Taken literally, never as a pattern.
    public var text: String
    public var kind: FileKind?
    /// Files at least this big; zero or less means no size filter.
    public var minimumBytes: Int64
    /// Files changed at or after this moment.
    public var modifiedAfter: Date?

    public init(text: String = "", kind: FileKind? = nil, minimumBytes: Int64 = 0, modifiedAfter: Date? = nil) {
        self.text = text
        self.kind = kind
        self.minimumBytes = minimumBytes
        self.modifiedAfter = modifiedAfter
    }

    /// The name text without surrounding spaces and line breaks.
    public var trimmedText: String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Nothing to search for: no text, no kind, no size, no date.
    public var isEmpty: Bool {
        trimmedText.isEmpty && kind == nil && minimumBytes <= 0 && modifiedAfter == nil
    }
}

/// What a file search found.
public struct FileSearchResult: Sendable, Equatable {
    /// Plain files, newest change first, at most the search's cap.
    public let files: [FileItem]
    /// There were more matches than `files` holds.
    public let isTruncated: Bool
    /// Spotlight did not answer (could not start, or took too long). Never set for an ordinary empty result.
    public let isUnavailable: Bool

    public init(files: [FileItem], isTruncated: Bool, isUnavailable: Bool = false) {
        self.files = files
        self.isTruncated = isTruncated
        self.isUnavailable = isUnavailable
    }
}

/// A file that was not moved, and why in plain words.
public struct FileFailure: Sendable, Equatable {
    public let file: FileItem
    public let reason: String

    public init(file: FileItem, reason: String) {
        self.file = file
        self.reason = reason
    }
}

/// What a move to the Trash really did. Only `moved` files count as freed (once the owner empties the Trash).
public struct FileTrashOutcome: Sendable, Equatable {
    public let moved: [FileItem]
    public let failed: [FileFailure]

    public init(moved: [FileItem], failed: [FileFailure]) {
        self.moved = moved
        self.failed = failed
    }

    /// The allocated bytes of the files that really moved.
    public var movedBytes: Int64 {
        CleanupMath.sum(moved.map(\.bytes))
    }
}

/// Why a file was not moved to the Trash.
public enum FileRefusal: Error, Equatable, Sendable {
    /// Its folder is not inside the home folder.
    case notInHome
    /// Inside `~/Library` or a folder whose name starts with a dot.
    case hiddenPlace
    /// Inside a protected place (system folders, the home folder itself, the app).
    case protected
    /// A link (an alias-like pointer), not a file.
    case link
    /// A folder, a package (such as an app) or anything else that is not a plain file.
    case notPlainFile
    /// On another disk or volume than the home folder.
    case otherVolume
    /// Another item took its place, or its size or modified date is not what was found.
    case changed
    /// Nothing is at the path any more.
    case vanished
    /// It could not be checked again before moving, so it was left alone.
    case unreadable
    /// macOS refused the move; carries its reason.
    case trashFailed(String)
    /// Moving the chosen copies would leave no copy of the file at all.
    case wouldLeaveNoCopy
    /// A file chosen for the Trash is not one of the copies in its group.
    case notInGroup
    /// No copy that would stay is still there, unchanged.
    case noKeptCopy

    public var text: String {
        switch self {
        case .notInHome: "It is not in your home folder."
        case .hiddenPlace: "It is in your Library folder or a hidden folder, so it is left alone."
        case .protected: "It is in a protected place."
        case .link: "It is a link to something else, not a file, so it is left alone."
        case .notPlainFile: "It is a folder, an app or something else that is not a single file, so it is left alone."
        case .otherVolume: "It is on another disk, so it is left alone."
        case .changed: "It changed since it was found, so it was left where it is."
        case .vanished: "It is no longer there."
        case .unreadable: "It could not be checked, so it was left where it is."
        case let .trashFailed(reason): "macOS could not move it to the Trash: \(reason)"
        case .wouldLeaveNoCopy: "That would leave no copy of this file, so nothing was moved."
        case .notInGroup: "One of the files chosen is not a copy in this group, so nothing was moved."
        case .noKeptCopy: "The copy you are keeping is no longer there unchanged, so nothing was moved."
        }
    }
}
