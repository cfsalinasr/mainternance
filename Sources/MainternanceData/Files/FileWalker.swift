import Foundation
import MainternanceDomain

/// One item the walker reports: a plain file, or a package counted as one item.
struct WalkedFile: Sendable {
    /// The absolute path exactly as found on disk.
    let path: String
    /// The item itself, read without following links.
    let stat: ItemStat
    /// A package folder (an app, a Photos library, anything macOS shows as one item): its contents are not reported.
    let isPackageRoot: Bool
    /// Allocated bytes: the file's own, or everything inside the package.
    let bytes: Int64
}

/// Walks the owner's home folder, depth first, with its own list of folders to visit (no recursion, so deep trees
/// cannot exhaust the stack).
///
/// Never entered or reported: `Library` at the top of home, any folder whose name starts with `.` (the Trash
/// among them), links (never followed and not counted), anything on another volume than the home folder, and
/// anything `isProtected` refuses. Only plain files and packages are reported; a file with several hard links is
/// reported once. Read-only.
struct FileWalker: Sendable {
    /// Folder extensions treated as one item even when macOS does not say it is a package.
    static let packageExtensions: Set<String> = [
        "app", "photoslibrary", "musiclibrary", "tvlibrary", "imovielibrary", "fcpbundle", "bundle", "framework",
        "plugin", "xcarchive"
    ]

    let home: URL
    let isProtected: @Sendable (String) -> Bool
    /// The volume (device) the item at a path is on, given its `lstat` reading. Tests replace it, since they cannot
    /// mount a volume.
    let volume: @Sendable (String, ItemStat) -> Int32
    let isPackage: @Sendable (String) -> Bool

    init(
        home: URL, isProtected: @escaping @Sendable (String) -> Bool,
        volume: @escaping @Sendable (String, ItemStat) -> Int32 = { $1.device },
        isPackage: @escaping @Sendable (String) -> Bool = FileWalker.readIsPackage
    ) {
        self.home = home
        self.isProtected = isProtected
        self.volume = volume
        self.isPackage = isPackage
    }

    /// Whether macOS shows the folder at `path` as a single item (or its extension says so).
    @Sendable
    static func readIsPackage(_ path: String) -> Bool {
        if packageExtensions.contains((path as NSString).pathExtension.lowercased()) {
            return true
        }
        let values = try? URL(fileURLWithPath: path, isDirectory: true).resourceValues(forKeys: [.isPackageKey])
        return values?.isPackage ?? false
    }

    /// What to do with one item found in a folder.
    private enum Step {
        case enter(String)
        case report(WalkedFile)
        case skip
    }

    /// Reports every plain file and package below the home folder. `shouldStop` is asked before every item; once
    /// it says true the walk returns at once. A folder that cannot be listed (or a package only partly read) is
    /// reported through `onFolderUnreadable` and the walk goes on.
    func walk(onFile: (WalkedFile) -> Void, onFolderUnreadable: () -> Void, shouldStop: () -> Bool) {
        let root = home.path
        guard case let .found(info) = ItemStat.read(root), info.type == .directory else {
            onFolderUnreadable()
            return
        }
        let library = (root as NSString).appendingPathComponent("Library")
        var pending = [root]
        var linkedSeen = Set<CleanupEntry.Identity>()
        while let folder = pending.popLast() {
            guard !shouldStop() else { return }
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder) else {
                onFolderUnreadable()
                continue
            }
            for name in names {
                guard !shouldStop() else { return }
                let path = (folder as NSString).appendingPathComponent(name)
                switch step(path, name: name, device: info.device, library: library, onUnreadable: onFolderUnreadable) {
                case let .enter(child):
                    pending.append(child)
                case let .report(file):
                    // Hard links share one identity: the first name found stands for all of them.
                    if !file.isPackageRoot, file.stat.linkCount > 1, !linkedSeen.insert(file.stat.identity).inserted {
                        continue
                    }
                    onFile(file)
                case .skip:
                    continue
                }
            }
        }
    }

    private func step(
        _ path: String, name: String, device: Int32, library: String, onUnreadable: () -> Void
    ) -> Step {
        // Removed while walking, or not checkable: nothing to count. Links are never followed or counted.
        guard case let .found(item) = ItemStat.read(path), item.type != .symbolicLink,
              volume(path, item) == device else { return .skip }
        if item.type == .directory {
            guard !name.hasPrefix("."), path != library, !isProtected(path) else { return .skip }
            guard isPackage(path) else { return .enter(path) }
            let (bytes, complete) = CleanupMeasurer.size(of: path, device: device)
            if !complete, !Task.isCancelled {
                onUnreadable()
            }
            return .report(WalkedFile(path: path, stat: item, isPackageRoot: true, bytes: bytes))
        }
        guard item.isRegular, !isProtected(path) else { return .skip }
        return .report(WalkedFile(path: path, stat: item, isPackageRoot: false, bytes: item.allocated))
    }
}
