import Darwin
import Foundation
import MainternanceDomain

/// One fixed Cleanup folder and which of its direct children count.
struct CleanupRoot: Sendable {
    enum Selection: Sendable {
        /// Every direct child, whatever it is.
        case everyChild
        /// Plain files ending `.dmg`, `.pkg` or `.iso` (any letter case) whose newest date (modified, created or
        /// added to the folder) is more than 30 days ago.
        case oldInstallers
    }

    let kind: CleanupKind
    let folder: URL
    let selection: Selection
}

/// The fixed Cleanup folders under a home folder. Nothing else is ever measured or moved.
enum CleanupRoots {
    static func standard(home: URL) -> [CleanupRoot] {
        [
            CleanupRoot(kind: .caches, folder: folder(home, "Library", "Caches"), selection: .everyChild),
            CleanupRoot(kind: .logs, folder: folder(home, "Library", "Logs"), selection: .everyChild),
            CleanupRoot(kind: .installers, folder: folder(home, "Downloads"), selection: .oldInstallers),
            CleanupRoot(
                kind: .developer, folder: folder(home, "Library", "Developer", "Xcode", "DerivedData"),
                selection: .everyChild
            )
        ]
    }

    private static func folder(_ home: URL, _ components: String...) -> URL {
        components.reduce(home) { $0.appendingPathComponent($1, isDirectory: true) }
    }
}

/// What `lstat` says about a path: links are never followed.
struct ItemStat: Sendable {
    enum Reading: Sendable {
        case found(ItemStat)
        /// Nothing is at the path.
        case missing
        /// Something may be there, but it could not be checked.
        case unreadable
    }

    let type: CleanupEntry.ItemType
    /// A plain file (not a link, folder, socket or device).
    let isRegular: Bool
    /// Allocated bytes (`st_blocks` is counted in 512-byte units).
    let allocated: Int64
    let identity: CleanupEntry.Identity
    let modified: Date
    /// When the item was made (`st_birthtime`).
    let created: Date

    var device: Int32 {
        identity.device
    }

    static func read(_ path: String) -> Reading {
        var info = stat()
        guard lstat(path, &info) == 0 else { return failure(errno) }
        return .found(ItemStat(info))
    }

    /// The child `name` of the already open folder `folder`, without following a link.
    static func read(_ name: String, in folder: Int32) -> Reading {
        var info = stat()
        guard fstatat(folder, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { return failure(errno) }
        return .found(ItemStat(info))
    }

    private static func failure(_ code: Int32) -> Reading {
        code == ENOENT || code == ENOTDIR ? .missing : .unreadable
    }

    init(_ info: stat) {
        let format = info.st_mode & S_IFMT
        type = switch format {
        case S_IFDIR: .directory
        case S_IFLNK: .symbolicLink
        default: .file
        }
        isRegular = format == S_IFREG
        allocated = Int64(info.st_blocks) * 512
        identity = CleanupEntry.Identity(device: info.st_dev, inode: info.st_ino)
        modified = Self.date(info.st_mtimespec)
        created = Self.date(info.st_birthtimespec)
    }

    private static func date(_ time: timespec) -> Date {
        Date(timeIntervalSince1970: Double(time.tv_sec) + Double(time.tv_nsec) / 1e9)
    }
}

/// The Cleanup folders plus the rules both the measurer and the mover apply, so the mover re-checks exactly what
/// the measurer would list.
struct CleanupRules: Sendable {
    static let installerExtensions: Set<String> = ["dmg", "pkg", "iso"]
    static let installerMinimumAge: TimeInterval = 30 * 86400

    /// A Cleanup folder as found now.
    enum FolderState {
        /// A real folder (not a link): its path as given, fully resolved, and which folder it is on disk.
        case folder(given: String, resolved: String, identity: CleanupEntry.Identity)
        /// Nothing there: the category does not appear.
        case absent
        /// A link, not a folder, or it could not be checked: reported, never followed.
        case unusable
    }

    let roots: [CleanupRoot]
    let now: @Sendable () -> Date
    /// When a file was put in its folder (Finder's "Date Added"); nil when not known.
    let dateAdded: @Sendable (String) -> Date?

    init(
        roots: [CleanupRoot], now: @escaping @Sendable () -> Date,
        dateAdded: @escaping @Sendable (String) -> Date? = CleanupRules.readDateAdded
    ) {
        self.roots = roots
        self.now = now
        self.dateAdded = dateAdded
    }

    /// The file system's "date added" for the item at `path` (a plain file: links are never passed here).
    @Sendable
    static func readDateAdded(_ path: String) -> Date? {
        let values = try? URL(fileURLWithPath: path).resourceValues(forKeys: [.addedToDirectoryDateKey])
        return values?.addedToDirectoryDate
    }

    /// Only a real folder counts; a folder that is itself a symbolic link is refused.
    static func open(_ root: CleanupRoot) -> FolderState {
        let given = root.folder.path
        switch ItemStat.read(given) {
        case .missing:
            return .absent
        case .unreadable:
            return .unusable
        case let .found(info):
            guard info.type == .directory, let resolved = resolve(given) else { return .unusable }
            return .folder(given: given, resolved: resolved, identity: info.identity)
        }
    }

    /// Every link in `path` resolved; nil when any part is missing.
    static func resolve(_ path: String) -> String? {
        guard let real = realpath(path, nil) else { return nil }
        defer { free(real) }
        return String(cString: real)
    }

    /// Whether the direct child at `path`, with this `lstat` reading, belongs to `root`.
    func accepts(path: String, _ info: ItemStat, in root: CleanupRoot, now: Date) -> Bool {
        let name = (path as NSString).lastPathComponent
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/") else { return false }
        switch root.selection {
        case .everyChild:
            return true
        case .oldInstallers:
            let suffix = (name as NSString).pathExtension.lowercased()
            guard info.isRegular, Self.installerExtensions.contains(suffix) else { return false }
            // A file downloaded (or copied in) recently can keep an old modification date: the newest date counts.
            let newest = [info.modified, info.created, dateAdded(path)].compactMap(\.self).max() ?? info.modified
            return now.timeIntervalSince(newest) > Self.installerMinimumAge
        }
    }
}
