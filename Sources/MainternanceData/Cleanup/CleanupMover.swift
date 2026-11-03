import Foundation
import MainternanceDomain

/// Moves measured entries to the Trash through `trash`, one at a time; never deletes anything.
///
/// Before each move the entry is checked again, and refused with a reason when any check fails:
/// 1. its parent, with every link resolved, is exactly one of the Cleanup folders (itself a real folder, not a link),
///    and its name is a plain name (not `.`, `..` or empty);
/// 2. the path is not protected (`isProtected`, which resolves links: a link into `/System` is refused);
/// 3. something is still there, of the kind that was measured (read without following links), and it still matches
///    its folder's rule (an installer touched since measuring no longer counts).
/// The item moved is the resolved parent plus the name, so a link entry moves as the link itself. A failed move is
/// reported and the rest continue; only entries that really moved are listed as moved.
///
/// Between the last check and the move another program could still swap the item; the move then takes the new item
/// at that same place in a Cleanup folder (to the Trash, where the owner can put it back), never anything elsewhere.
struct CleanupMover: CleanupMoving {
    let rules: CleanupRules
    let trash: @Sendable (URL) throws -> Void
    let isProtected: @Sendable (String) -> Bool

    func moveToTrash(_ entries: [CleanupEntry]) async -> CleanupOutcome {
        let now = rules.now()
        let folders = rules.roots.compactMap { root -> (root: CleanupRoot, resolved: String)? in
            guard case let .folder(_, resolved, _) = CleanupRules.open(root) else { return nil }
            return (root, resolved)
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

    private func check(
        _ entry: CleanupEntry, folders: [(root: CleanupRoot, resolved: String)], now: Date
    ) -> Result<URL, CleanupRefusal> {
        let path = entry.id as NSString
        let name = path.lastPathComponent
        guard entry.id.hasPrefix("/"), !entry.id.hasSuffix("/"), name != ".", name != "..", !name.isEmpty,
              let parent = CleanupRules.resolve(path.deletingLastPathComponent),
              let folder = folders.first(where: { $0.resolved == parent })
        else { return .failure(.notInCleanupFolder) }
        let target = (parent as NSString).appendingPathComponent(name)
        guard !isProtected(target) else { return .failure(.protected) }
        switch ItemStat.read(target) {
        case .missing:
            return .failure(.vanished)
        case .unreadable:
            return .failure(.unreadable)
        case let .found(info):
            guard info.type == entry.type else { return .failure(.changed) }
            guard rules.accepts(name: name, info, in: folder.root, now: now) else {
                return .failure(.notInCleanupFolder)
            }
            return .success(URL(fileURLWithPath: target, isDirectory: info.type == .directory))
        }
    }
}
