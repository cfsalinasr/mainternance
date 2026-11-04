import Darwin
import Foundation
import MainternanceDomain

/// Moves plain files the owner chose (search, large-file and duplicate results) to the Trash through `trash`, one at
/// a time; never deletes anything.
///
/// Right before each move the file is checked again, in the same order as `CleanupMover` and `AppMover` (see their
/// doc comments; the checks are repeated here rather than shared, because the allowed folder is any ordinary folder
/// in the home folder, not a fixed list). It is refused with a reason when:
/// 1. its path is not a plain absolute path (`.`, `..`, a trailing slash), or its parent, with every link resolved,
///    is not the home folder or a folder inside it (`notInHome`), or that parent is inside `~/Library` or has a
///    folder whose name starts with `.` on the way (`hiddenPlace`; `Library` in any letter case);
/// 2. that parent, opened without following a link (`O_NOFOLLOW | O_DIRECTORY`), is not the same folder (device and
///    inode) the path named a moment before;
/// 3. the file, read inside that open folder without following links (`fstatat`), is gone, is a link, a folder, a
///    package or anything but a plain file, or is not unchanged since it was scanned: the same item (device and
///    inode), the same allocated size (what `FileItem.bytes` holds) and the same modified date. A file with no
///    recorded identity cannot be checked and is refused;
/// 4. it is on another volume than the home folder;
/// 5. the path is protected (`isProtected`);
/// 6. last, just before the move, the path is read again (`lstat`) and must still name exactly that file, unchanged.
/// The item moved is the resolved parent plus the name. One refusal, or one move macOS refuses, never stops the
/// rest; only files that really moved are listed as moved and counted in `movedBytes`.
///
/// `moveDuplicatesToTrash` adds, before anything moves: every file to remove must be one of the group's copies
/// exactly as the group recorded it, and at least one copy must stay. Then, before each single move, at least one
/// kept copy must still be on disk unchanged (same item, size and modified date), and not the same item as a file
/// being removed (a hard link is not a second copy). When that fails, the file is refused and never offered to the
/// Trash, so the group is never left with no copy.
///
/// What is still possible is the same as for `CleanupMover`: `trash` takes a path, so another program running as
/// the same user could swap the file, or remove the kept copy, in the moment between the last check and the move.
/// Whatever was moved went to the Trash, where the owner can put it back; it is never a permanent delete.
///
/// Tests replace `trash` with a fake that moves into a temp folder, and use a temp home folder.
struct FileTrasher: FileTrashing {
    let home: URL
    let trash: @Sendable (URL) throws -> Void
    let isProtected: @Sendable (String) -> Bool
    /// The volume (device) the item at a path is on, given its `lstat` reading. Tests replace it.
    let volume: @Sendable (String, ItemStat) -> Int32

    init(
        home: URL, trash: @escaping @Sendable (URL) throws -> Void,
        isProtected: @escaping @Sendable (String) -> Bool,
        volume: @escaping @Sendable (String, ItemStat) -> Int32 = { $1.device }
    ) {
        self.home = home
        self.trash = trash
        self.isProtected = isProtected
        self.volume = volume
    }

    /// The home folder as found when the move started.
    private struct Home {
        let resolved: String
        let device: Int32
    }

    /// A file whose path passed step 1: its plain name, its resolved parent and the path that would move.
    private struct Candidate {
        let file: FileItem
        let identity: CleanupEntry.Identity
        let name: String
        let parent: String
        let target: String
    }

    func moveToTrash(_ files: [FileItem]) async -> FileTrashOutcome {
        let home = homeState()
        var moved: [FileItem] = []
        var failed: [FileFailure] = []
        for file in files {
            if let refusal = checkAndMove(file, home: home) {
                failed.append(FileFailure(file: file, reason: refusal.text))
            } else {
                moved.append(file)
            }
        }
        return FileTrashOutcome(moved: moved, failed: failed)
    }

    func moveDuplicatesToTrash(_ group: DuplicateGroup, remove: [FileItem]) async -> FileTrashOutcome {
        if let refusal = Self.groupRefusal(group, remove: remove) {
            return FileTrashOutcome(
                moved: [], failed: remove.map { FileFailure(file: $0, reason: refusal.text) }
            )
        }
        let removing = Set(remove.map(\.id))
        let removedIdentities = Set(remove.compactMap(\.identity))
        let kept = group.files.filter { !removing.contains($0.id) }
        let home = homeState()
        var moved: [FileItem] = []
        var failed: [FileFailure] = []
        for file in remove {
            // Checked again before every move: a kept copy removed meanwhile must stop the rest.
            guard kept.contains(where: { Self.stillThere($0, notAmong: removedIdentities) }) else {
                failed.append(FileFailure(file: file, reason: FileRefusal.noKeptCopy.text))
                continue
            }
            if let refusal = checkAndMove(file, home: home) {
                failed.append(FileFailure(file: file, reason: refusal.text))
            } else {
                moved.append(file)
            }
        }
        return FileTrashOutcome(moved: moved, failed: failed)
    }

    // MARK: Duplicates

    /// Why nothing at all may move: a file is not one of the group's copies as recorded, or no copy would stay.
    private static func groupRefusal(_ group: DuplicateGroup, remove: [FileItem]) -> FileRefusal? {
        guard !remove.isEmpty else { return nil }
        guard remove.allSatisfy({ group.files.contains($0) }) else { return .notInGroup }
        let removing = Set(remove.map(\.id))
        guard group.files.contains(where: { !removing.contains($0.id) }) else { return .wouldLeaveNoCopy }
        return nil
    }

    /// A kept copy is still on disk as a plain file, the same item with the same size and date as recorded, and is
    /// not the same item as a file being removed.
    private static func stillThere(_ copy: FileItem, notAmong removed: Set<CleanupEntry.Identity>) -> Bool {
        guard let identity = copy.identity, !removed.contains(identity),
              case let .found(info) = ItemStat.read(copy.id) else { return false }
        return info.isRegular && unchanged(copy, info)
    }

    /// The reading names the scanned item: same device and inode, allocated size and modified date.
    private static func unchanged(_ file: FileItem, _ info: ItemStat) -> Bool {
        info.identity == file.identity && info.allocated == file.bytes && info.modified == file.modified
    }

    // MARK: Checking and moving

    private func homeState() -> Home? {
        guard let resolved = CleanupRules.resolve(home.path), case let .found(info) = ItemStat.read(resolved),
              info.type == .directory else { return nil }
        return Home(resolved: resolved, device: info.device)
    }

    /// nil when the file moved; otherwise why not.
    private func checkAndMove(_ file: FileItem, home: Home?) -> FileRefusal? {
        guard let home else { return .unreadable }
        switch check(file, home: home) {
        case let .failure(refusal):
            return refusal
        case let .success(target):
            do {
                try trash(target)
                return nil
            } catch {
                return .trashFailed(DisplayText.clean(error.localizedDescription))
            }
        }
    }

    /// Step 1: a plain path whose resolved parent is an ordinary folder in the home folder.
    private func check(_ file: FileItem, home: Home) -> Result<URL, FileRefusal> {
        let path = file.id as NSString
        let name = path.lastPathComponent
        guard file.id.hasPrefix("/"), !file.id.hasSuffix("/"), name != ".", name != "..", !name.isEmpty else {
            return .failure(.notInHome)
        }
        // A missing folder means the file cannot be there either.
        guard let parent = CleanupRules.resolve(path.deletingLastPathComponent) else { return .failure(.vanished) }
        let below: [Substring]
        if parent == home.resolved {
            below = []
        } else if parent.hasPrefix(home.resolved + "/") {
            below = parent.dropFirst(home.resolved.count + 1).split(separator: "/")
        } else {
            return .failure(.notInHome)
        }
        if let first = below.first, first.caseInsensitiveCompare("Library") == .orderedSame {
            return .failure(.hiddenPlace)
        }
        guard !below.contains(where: { $0.hasPrefix(".") }) else { return .failure(.hiddenPlace) }
        guard let identity = file.identity else { return .failure(.unreadable) }
        let candidate = Candidate(
            file: file, identity: identity, name: name, parent: parent,
            target: (parent as NSString).appendingPathComponent(name)
        )
        return open(candidate, home: home)
    }

    /// Step 2: the parent, opened without following a link, is the folder the path named.
    private func open(_ candidate: Candidate, home: Home) -> Result<URL, FileRefusal> {
        guard case let .found(named) = ItemStat.read(candidate.parent), named.type == .directory else {
            return .failure(.changed)
        }
        let descriptor = Darwin.open(candidate.parent, O_RDONLY | O_NOFOLLOW | O_DIRECTORY | O_CLOEXEC)
        guard descriptor >= 0 else { return .failure(errno == EACCES ? .unreadable : .changed) }
        defer { close(descriptor) }
        var opened = stat()
        guard fstat(descriptor, &opened) == 0 else { return .failure(.unreadable) }
        guard CleanupEntry.Identity(device: opened.st_dev, inode: opened.st_ino) == named.identity else {
            return .failure(.changed)
        }
        return inspect(candidate, in: descriptor, home: home)
    }

    /// Steps 3 to 6, with the parent open as `descriptor`.
    private func inspect(_ candidate: Candidate, in descriptor: Int32, home: Home) -> Result<URL, FileRefusal> {
        let info: ItemStat
        switch ItemStat.read(candidate.name, in: descriptor) {
        case .missing:
            return .failure(.vanished)
        case .unreadable:
            return .failure(.unreadable)
        case let .found(found):
            info = found
        }
        guard info.type != .symbolicLink else { return .failure(.link) }
        guard info.isRegular else { return .failure(.notPlainFile) }
        guard info.identity == candidate.identity, Self.unchanged(candidate.file, info) else {
            return .failure(.changed)
        }
        guard volume(candidate.target, info) == home.device else { return .failure(.otherVolume) }
        guard !isProtected(candidate.target) else { return .failure(.protected) }
        // The path must still name exactly the file checked inside the open folder, right before the move.
        guard case let .found(last) = ItemStat.read(candidate.target), last.isRegular,
              Self.unchanged(candidate.file, last) else { return .failure(.changed) }
        return .success(URL(fileURLWithPath: candidate.target, isDirectory: false))
    }
}
