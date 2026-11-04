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
