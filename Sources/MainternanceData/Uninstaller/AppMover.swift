import Darwin
import Foundation
import MainternanceDomain

/// Moves an app, then its chosen leftovers, to the Trash through `trash`, one at a time; never deletes anything.
///
/// The app goes first. If it is refused, or macOS cannot move it, no leftover is tried: they are all reported as
/// skipped, so an app is never left half-working. With `includeApp` false only the leftovers are moved.
///
/// Right before each move the item is checked again, in the same order as `CleanupMover` (see its doc comment),
/// with "the Cleanup folders" replaced by the allowed folders: the application folders for the app, the fixed
/// `~/Library` folders (`LeftoverFinder.libraryFolders`) for leftovers. It is refused with a reason when:
/// 1. its parent, with every link resolved, is not exactly one of the allowed folders, or its name is not a plain
///    name (an app's name must also end `.app`);
/// 2. that folder, opened without following a link (`O_NOFOLLOW | O_DIRECTORY`), is no longer the same folder on
///    disk (device and inode) it was when this move started;
/// 3. the item, read inside that open folder without following links, is gone, or is not of the kind and the same
///    item (device and inode) that was measured; an item with no recorded identity cannot be checked and is refused;
/// 4. it is on another volume than its folder;
/// 5. the path is protected (`isProtected`: system places, the home folder itself, the running Mainternance
///    bundle); a link into a protected place gets its own reason;
/// 6. for the app only: its `Info.plist`, read again now (`AppLister.readPlist`), names one of Apple's apps
///    (`com.apple.`), names another identifier than when it was listed, or names an app that is running;
/// 7. last, just before the move, the path is read again (`lstat`) and must name exactly the item checked in the
///    open folder.
/// The item moved is the resolved parent plus the name, so a link moves as the link itself. A failed leftover is
/// reported and the rest continue; only what really moved is listed as moved and counted in `movedBytes`.
///
/// What is still possible is the same as for `CleanupMover`: `trash` takes a path, so another program running as the
/// same user could swap the item in the moment between step 7 and the move; whatever it put there goes to the Trash,
/// never a permanent delete. An app without an identifier cannot be checked for running (the check is by identifier).
///
/// Tests replace `trash` with a fake that moves into a temp folder, and use a temp home and Applications folder.
struct AppMover: AppUninstalling {
    let home: URL
    let applicationFolders: [URL]
    let isRunning: @Sendable (String) -> Bool
    let trash: @Sendable (URL) throws -> Void
    let isProtected: @Sendable (String) -> Bool
    /// The volume (device) the item at a path is on, given its `lstat` reading. Tests replace it.
    let volume: @Sendable (String, ItemStat) -> Int32

    init(
        home: URL, applicationFolders: [URL], isRunning: @escaping @Sendable (String) -> Bool,
        trash: @escaping @Sendable (URL) throws -> Void, isProtected: @escaping @Sendable (String) -> Bool,
        volume: @escaping @Sendable (String, ItemStat) -> Int32 = { $1.device }
    ) {
        self.home = home
        self.applicationFolders = applicationFolders
        self.isRunning = isRunning
        self.trash = trash
        self.isProtected = isProtected
        self.volume = volume
    }

    /// An allowed folder as found when the move started.
    private struct Folder {
        let resolved: String
        let identity: CleanupEntry.Identity
    }

    /// One item being checked: its path as given and what was measured.
    private struct Item {
        let path: String
        let type: CleanupEntry.ItemType
        let identity: CleanupEntry.Identity?
        /// Set for the app, which gets the extra checks of step 6.
        let app: InstalledApp?
    }

    /// An item whose parent passed steps 1 and 2: its plain name, the path that would move, and its folder.
    private struct Candidate {
        let item: Item
        let identity: CleanupEntry.Identity
        let name: String
        let target: String
        let folder: Folder
    }

    /// A refusal in plain words (a `CleanupRefusal` or an `UninstallRefusal`).
    private struct Refused: Error {
        let text: String

        init(_ refusal: CleanupRefusal) {
            text = refusal.text
        }

        init(_ refusal: UninstallRefusal) {
            text = refusal.text
        }
    }

    func moveToTrash(
        app: InstalledApp, appBytes: Int64, leftovers: [Leftover], includeApp: Bool
    ) async -> UninstallOutcome {
        if includeApp {
            let item = Item(path: app.id, type: .directory, identity: app.identity, app: app)
            if let failure = checkAndMove(item, in: applicationFolderStates()) {
                return UninstallOutcome(
                    appMoved: false, appFailure: failure, appBytes: appBytes, movedLeftovers: [],
                    failedLeftovers: [], skipped: leftovers
                )
            }
        }
        // Without the app, its leftovers still must not move from under a running app.
        if !includeApp, app.bundleID != nil, let running = runningRefusal(app) {
            return UninstallOutcome(
                appMoved: false, appFailure: nil, appBytes: appBytes, movedLeftovers: [],
                failedLeftovers: leftovers.map { LeftoverFailure(leftover: $0, reason: running.text) }, skipped: []
            )
        }
        let folders = libraryFolderStates()
        var moved: [Leftover] = []
        var failed: [LeftoverFailure] = []
        for leftover in leftovers {
            let item = Item(path: leftover.id, type: leftover.type, identity: leftover.identity, app: nil)
            if let failure = checkAndMove(item, in: folders) {
                failed.append(LeftoverFailure(leftover: leftover, reason: failure))
            } else {
                moved.append(leftover)
            }
        }
        return UninstallOutcome(
            appMoved: includeApp, appFailure: nil, appBytes: appBytes, movedLeftovers: moved,
            failedLeftovers: failed, skipped: []
        )
    }

    /// Leftovers only: the app's `Info.plist`, read now at its listed place, names an app that is running.
    private func runningRefusal(_ app: InstalledApp) -> Refused? {
        let raw = AppLister.readPlist(in: app.id)?["CFBundleIdentifier"] as? String
        if let raw, !raw.isEmpty, isRunning(raw) {
            return Refused(.running)
        }
        // A missing or unreadable plist falls back to the identifier from listing.
        if raw == nil, let listed = app.bundleID, isRunning(listed) {
            return Refused(.running)
        }
        return nil
    }

    // MARK: Allowed folders

    /// The application folders that are real folders (not links) now.
    private func applicationFolderStates() -> [Folder] {
        applicationFolders.compactMap { url in
            guard case let .found(info) = ItemStat.read(url.path), info.type == .directory,
                  let resolved = CleanupRules.resolve(url.path) else { return nil }
            return Folder(resolved: resolved, identity: info.identity)
        }
    }

    /// The fixed `~/Library` folders, with the same rules as the Cleanup folders: none of them, nor `Library`, may be
    /// a link.
    private func libraryFolderStates() -> [Folder] {
        LeftoverFinder.libraryFolders.compactMap { name in
            guard case let .folder(_, resolved, identity) = CleanupRules.open(
                home: home, relative: ["Library", name]
            ) else { return nil }
            return Folder(resolved: resolved, identity: identity)
        }
    }

    // MARK: Checking and moving

    /// nil when the item moved; otherwise why not.
    private func checkAndMove(_ item: Item, in folders: [Folder]) -> String? {
        switch check(item, in: folders) {
        case let .failure(refused):
            return refused.text
        case let .success(target):
            do {
                try trash(target)
                return nil
            } catch {
                return CleanupRefusal.trashFailed(DisplayText.clean(error.localizedDescription)).text
            }
        }
    }

    /// Steps 1 and 2: the parent is an allowed folder, still the same folder on disk.
    private func check(_ item: Item, in folders: [Folder]) -> Result<URL, Refused> {
        let path = item.path as NSString
        let name = path.lastPathComponent
        guard item.path.hasPrefix("/"), !item.path.hasSuffix("/"), name != ".", name != "..", !name.isEmpty,
              item.app == nil || name.hasSuffix(".app"),
              let parent = CleanupRules.resolve(path.deletingLastPathComponent),
              let folder = folders.first(where: { $0.resolved == parent })
        else { return .failure(Refused(.notInUninstallerFolder)) }
        guard let identity = item.identity else { return .failure(Refused(.unreadable)) }
        let descriptor = open(folder.resolved, O_RDONLY | O_NOFOLLOW | O_DIRECTORY | O_CLOEXEC)
        guard descriptor >= 0 else { return .failure(Refused(errno == EACCES ? .unreadable : .changed)) }
        defer { close(descriptor) }
        var opened = stat()
        guard fstat(descriptor, &opened) == 0 else { return .failure(Refused(.unreadable)) }
        guard CleanupEntry.Identity(device: opened.st_dev, inode: opened.st_ino) == folder.identity else {
            return .failure(Refused(.changed))
        }
        let candidate = Candidate(
            item: item, identity: identity, name: name, target: (parent as NSString).appendingPathComponent(name),
            folder: folder
        )
        return inspect(candidate, in: descriptor)
    }

    /// Steps 3 to 7, with the allowed folder open as `descriptor`.
    private func inspect(_ candidate: Candidate, in descriptor: Int32) -> Result<URL, Refused> {
        let target = candidate.target
        let info: ItemStat
        switch ItemStat.read(candidate.name, in: descriptor) {
        case .missing:
            return .failure(Refused(.vanished))
        case .unreadable:
            return .failure(Refused(.unreadable))
        case let .found(found):
            info = found
        }
        guard info.type == candidate.item.type, info.identity == candidate.identity else {
            return .failure(Refused(.changed))
        }
        guard volume(target, info) == candidate.folder.identity.device else {
            return .failure(Refused(UninstallRefusal.otherVolume))
        }
        guard !isProtected(target) else {
            return .failure(Refused(info.type == .symbolicLink ? .protectedLink : .protected))
        }
        if let app = candidate.item.app, let refused = recheck(app, at: target) {
            return .failure(refused)
        }
        // The path must still name exactly the item checked inside the open folder, right before the move.
        guard case let .found(last) = ItemStat.read(target), last.type == info.type, last.identity == info.identity
        else { return .failure(Refused(.changed)) }
        return .success(URL(fileURLWithPath: target, isDirectory: info.type == .directory))
    }

    /// Step 6: the app's own `Info.plist`, read again now.
    private func recheck(_ app: InstalledApp, at target: String) -> Refused? {
        let raw = AppLister.readPlist(in: target)?["CFBundleIdentifier"] as? String
        if AppLister.isAppleIdentifier(raw) {
            return Refused(.appleApp)
        }
        guard AppLister.validIdentifier(raw) == AppLister.validIdentifier(app.bundleID) else {
            return Refused(.changed)
        }
        // The raw text is only looked up, never used as a path, so even an identifier the lister did not accept
        // is checked.
        if let raw, !raw.isEmpty, isRunning(raw) {
            return Refused(.running)
        }
        return nil
    }
}
