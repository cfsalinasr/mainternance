import Darwin
import Foundation
import MainternanceDomain

/// Moves measured entries to the Trash through `trash`, one at a time; never deletes anything.
///
/// Right before each move the entry is checked again, and refused with a reason when any check fails:
/// 1. its parent, with every link resolved, is exactly one of the Cleanup folders, and its name is a plain name
///    (not `.`, `..` or empty);
/// 2. that Cleanup folder is opened without following a link (`O_NOFOLLOW | O_DIRECTORY`) and must still be the
///    same folder on disk (device and inode) it was when this move started: a folder replaced meanwhile is refused;
/// 3. the entry is read inside that open folder without following links: something is still there, of the kind
///    that was measured, and the same item (device and inode) the measurement recorded; an entry with no recorded
///    identity is refused as unreadable, like the other movers do;
/// 4. it is on the same volume as its Cleanup folder (a folder mounted from another volume is refused);
/// 5. the path is not protected (`isProtected`, which resolves links) and does not hold the running app
///    (`rules.holdsApp`); a link into a protected place is refused with its own reason;
/// 6. it still matches its folder's rule (an installer touched since measuring no longer counts);
/// 7. last, just before the move, the path is read again (`lstat`) and must name exactly the item checked in the
///    open folder: a file or folder that became a link, or any other swap, is refused as changed.
/// The item moved is the resolved parent plus the name, so a link entry moves as the link itself. A failed move is
/// reported and the rest continue; only entries that really moved are listed as moved.
///
/// What is still possible: `trash` takes a path, not the open folder, so another program running as the same user
/// could swap the Cleanup folder (or the entry) in the moment between step 7 and the move. The move then takes
/// whatever is at that path at that instant; it only ever goes to the Trash, where the owner can put it back, and
/// it is never a permanent delete. No program running as someone else can do this in the owner's home folder.
///
/// Tests replace `trash` with a fake that moves into a temp folder. The real move (`SystemTrash.move`) is pinned by
/// `SystemTrashIntegrationTests` on a temporary disk image: a link goes to the Trash as the link, its target stays.
struct CleanupMover: CleanupMoving {
    let rules: CleanupRules
    let trash: @Sendable (URL) throws -> Void
    let isProtected: @Sendable (String) -> Bool

    /// A Cleanup folder as found when the move started.
    private struct Folder {
        let root: CleanupRoot
        let resolved: String
        let identity: CleanupEntry.Identity
    }

    /// One entry being checked: what was measured, its plain name and the path that would move.
    private struct Candidate {
        let entry: CleanupEntry
        let name: String
        let target: String
        let folder: Folder
    }

    func moveToTrash(_ entries: [CleanupEntry]) async -> CleanupOutcome {
        let now = rules.now()
        let folders = rules.roots.compactMap { root -> Folder? in
            guard case let .folder(_, resolved, identity) = CleanupRules.open(root) else { return nil }
            return Folder(root: root, resolved: resolved, identity: identity)
        }
        var moved: [CleanupEntry] = []
        var failed: [CleanupFailure] = []
        for entry in entries {
            switch check(entry, folders: folders, now: now) {
            case let .failure(refusal):
                failed.append(CleanupFailure(entry: entry, reason: refusal.text))
            case let .success(target):
                do {
                    try trash(target)
                    moved.append(entry)
                } catch {
                    let reason = DisplayText.clean(error.localizedDescription)
                    failed.append(CleanupFailure(entry: entry, reason: CleanupRefusal.trashFailed(reason).text))
                }
            }
        }
        return CleanupOutcome(moved: moved, failed: failed)
    }

    private func check(_ entry: CleanupEntry, folders: [Folder], now: Date) -> Result<URL, CleanupRefusal> {
        let path = entry.id as NSString
        let name = path.lastPathComponent
        guard entry.id.hasPrefix("/"), !entry.id.hasSuffix("/"), name != ".", name != "..", !name.isEmpty,
              let parent = CleanupRules.resolve(path.deletingLastPathComponent),
              let folder = folders.first(where: { $0.resolved == parent })
        else { return .failure(.notInCleanupFolder) }
        let candidate = Candidate(
            entry: entry, name: name, target: (parent as NSString).appendingPathComponent(name), folder: folder
        )
        let descriptor = open(folder.resolved, O_RDONLY | O_NOFOLLOW | O_DIRECTORY | O_CLOEXEC)
        guard descriptor >= 0 else { return .failure(errno == EACCES ? .unreadable : .changed) }
        defer { close(descriptor) }
        var opened = stat()
        guard fstat(descriptor, &opened) == 0 else { return .failure(.unreadable) }
        guard CleanupEntry.Identity(device: opened.st_dev, inode: opened.st_ino) == folder.identity else {
            return .failure(.changed)
        }
        return inspect(candidate, in: descriptor, now: now)
    }

    /// Steps 3 to 7, with the Cleanup folder open as `folder`.
    private func inspect(_ candidate: Candidate, in folder: Int32, now: Date) -> Result<URL, CleanupRefusal> {
        let entry = candidate.entry
        let info: ItemStat
        switch ItemStat.read(candidate.name, in: folder) {
        case .missing:
            return .failure(.vanished)
        case .unreadable:
            return .failure(.unreadable)
        case let .found(found):
            info = found
        }
        guard let identity = entry.identity else { return .failure(.unreadable) }
        guard info.type == entry.type, identity == info.identity else { return .failure(.changed) }
        guard rules.volume(candidate.target, info) == candidate.folder.identity.device else {
            return .failure(.otherVolume)
        }
        let holdsTheApp = rules.holdsApp(candidate.target)
        guard !holdsTheApp, !isProtected(candidate.target) else {
            if info.type == .symbolicLink {
                return .failure(.protectedLink)
            }
            return .failure(holdsTheApp ? .holdsApp : .protected)
        }
        guard rules.accepts(path: candidate.target, info, in: candidate.folder.root, now: now) else {
            return .failure(.notInCleanupFolder)
        }
        // The path must still name exactly the item checked inside the open folder, right before the move.
        guard case let .found(last) = ItemStat.read(candidate.target), last.type == info.type,
              last.identity == info.identity
        else { return .failure(.changed) }
        return .success(URL(fileURLWithPath: candidate.target, isDirectory: info.type == .directory))
    }
}
