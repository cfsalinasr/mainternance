import Darwin
import Foundation
import MainternanceDomain

/// Restoring a quarantined file to its original folder.
///
/// Race safety. The destination folder is resolved (`realpath`) and checked against `ProtectedPaths`, then opened
/// once with `O_DIRECTORY | O_NOFOLLOW` (a folder swapped for a symlink after the check is refused). The decision is
/// re-checked against the physical path of the folder really opened (`F_GETPATH`), which catches a folder higher up
/// being swapped between the check and the open. From then on everything happens relative to that descriptor: the
/// free-name lookup (`fstatat`), the partial copy (`openat` with `O_EXCL`), the final rename (`renameatx_np` with
/// `RENAME_EXCL`, so nothing is ever overwritten) and the permission reset (`openat` + identity check + `fchmod`).
///
/// Content check. The vault copy is the last copy of the content, so both ways back must place exactly the recorded
/// bytes, and the record (with its digest) is only dropped once the placed entry is the verified file:
/// - Same volume: the vault file is hashed through the descriptor opened at the start (SHA-256 and size against the
///   record) before it moves. The rename itself goes by the vault path, so afterwards the entry it placed is checked
///   (`fstatat` in the destination folder, no follow) to be that same file (device, inode, size). If it is not, the
///   placed entry is moved back to the vault path (`RENAME_EXCL`) and the restore fails with the record kept; if even
///   that move fails, the restore fails with a message saying where the unexpected file is.
/// - Other volume: the bytes written to the new partial are hashed while copying. After the rename, the entry placed
///   must be the very file that was copied (device, inode, size) before the vault copy is discarded. If it is not,
///   the vault copy and the record are kept and nothing is removed (neither the placed entry nor whatever now has the
///   partial's name, as neither is known to be ours).
///
/// Residual, accepted and documented:
/// - Same volume: the identity check binds the placed entry to the verified inode, not to its bytes. A process that
///   can write to the vault file (mode `0o600` in the user's own `0o700` quarantine folder, so only the user's own
///   processes) could rewrite it in place between the hash and the rename. It could equally rewrite the restored file
///   right after any restore, so this gives it nothing new.
/// - The checked folder itself can still be renamed (as a whole) after the `F_GETPATH` re-check. The file then lands
///   in that very folder, under its new name, and the returned path says where. A process that can rename that
///   folder could move the restored file there afterwards anyway, so this gives it nothing new.
/// - Cleaning up a half-written `.<uuid>.partial` after a failed attempt goes through `QuarantineRemoval`
///   (`.restorePartial`), which reopens the folder by its checked physical path. If that path was swapped meanwhile,
///   the cleanup can only remove a regular file with that exact app-chosen name, or leave our partial behind.
extension QuarantineStore {
    /// Where a restored file went inside its folder, and the identity of that file.
    private struct Placed {
        let name: String
        let identity: stat
    }

    /// One try at putting the file back under `name`; `createdPartial` tells whether it wrote a `.<uuid>.partial`.
    private struct Attempt {
        let id: UUID
        let source: QuarantineFiles.OpenFile
        let name: String
        let original: URL
        /// The recorded SHA-256 of the quarantined content.
        let expected: String
        var createdPartial = false
    }

    /// Restores the file and returns the path it really went to (`a (restored).txt` when something is in the way).
    /// A failed permission reset after the move does not fail the restore: the file is back, and keeps the
    /// quarantine's `0o600` until the permissions are fixed by hand. Special bits (setuid, sticky) are never restored.
    public func restore(_ id: UUID) throws -> String {
        var entries = try load()
        guard let index = entries.firstIndex(where: { $0.state == .stored && $0.record.id == id }) else {
            throw QuarantineError.missing
        }
        let record = entries[index].record
        guard !ProtectedPaths.isProtected(record.originalPath, including: [directory]) else {
            throw QuarantineError.protectedPath
        }
        let original = URL(fileURLWithPath: record.originalPath)
        let folder = try openDestination(of: original)
        defer { folder.close() }
        let placed = try moveOut(id: id, to: original, expected: record.sha256, in: folder)
        entries.remove(at: index)
        try? write(entries)
        removeSidecar(id)
        if !hooks.failRestorePermissions {
            try? folder.setPermissions(record.originalPermissions, of: placed.name, expecting: placed.identity)
        }
        return finalPath(of: placed.name, original: original, folder: folder)
    }

    /// Resolves, checks and opens the folder `original` goes back to, and re-checks the folder really opened.
    private func openDestination(of original: URL) throws -> RestoreFolder {
        let name = original.lastPathComponent
        let resolved: String
        do { resolved = try QuarantineFiles.realParent(of: original.path) } catch {
            throw QuarantineError.restoreTargetMissing
        }
        guard !ProtectedPaths.isProtected(resolved + "/" + name, including: [directory]) else {
            throw QuarantineError.protectedPath
        }
        hooks.beforeRestoreFolderOpen?()
        let folder = try RestoreFolder.open(resolved)
        guard !ProtectedPaths.isProtected(folder.path + "/" + name, including: [directory]) else {
            folder.close()
            throw QuarantineError.protectedPath
        }
        hooks.afterRestoreFolderOpen?()
        return folder
    }

    /// The path as recorded (keeping how it was spelled, for example through a symlinked folder) while the opened
    /// folder is still where it was checked; otherwise where the folder really is now.
    private func finalPath(of name: String, original: URL, folder: RestoreFolder) -> String {
        if let now = folder.currentPath(), now != folder.path {
            return (now as NSString).appendingPathComponent(name)
        }
        return original.deletingLastPathComponent().appendingPathComponent(name).path
    }

    /// Moves the quarantined item into `folder` next to `original`, never overwriting. Returns the name it got and
    /// the identity of the restored file.
    private func moveOut(id: UUID, to original: URL, expected: String, in folder: RestoreFolder) throws -> Placed {
        let source: QuarantineFiles.OpenFile
        do { source = try QuarantineFiles.openRegular(vaultPath(id)) } catch QuarantineError.notRegularFile {
            throw QuarantineError.ioFailure("The quarantined item is not a regular file, so nothing was restored.")
        }
        defer { source.close() }
        for _ in 0 ..< 8 {
            let name = freeName(for: original.lastPathComponent, in: folder)
            guard !ProtectedPaths.isProtected(folder.path + "/" + name, including: [directory]) else {
                throw QuarantineError.protectedPath
            }
            var attempt = Attempt(id: id, source: source, name: name, original: original, expected: expected)
            do {
                let identity = try moveOutOnce(&attempt, folder: folder)
                return Placed(name: name, identity: identity)
            } catch QuarantineFiles.MoveFailure.destinationExists {
                // Something appeared at this name meanwhile: drop our half-written copy (the next try creates it
                // again with O_EXCL) and pick the next free name.
                discardPartial(of: attempt, in: folder)
                continue
            } catch {
                discardPartial(of: attempt, in: folder)
                throw Self.wrap(error)
            }
        }
        throw QuarantineError.ioFailure("No free name was found to restore the file.")
    }

    /// Only a partial this very attempt created is ours to remove; the plain move never creates one.
    private func discardPartial(of attempt: Attempt, in folder: RestoreFolder) {
        if attempt.createdPartial {
            QuarantineRemoval.discard(.restorePartial(folder: folder.path, id: attempt.id))
        }
    }

    private func moveOutOnce(_ attempt: inout Attempt, folder: RestoreFolder) throws -> stat {
        if !hooks.forceCopy, folder.device() == attempt.source.info.st_dev {
            do {
                try moveOnce(attempt, folder: folder)
                return attempt.source.info
            } catch QuarantineFiles.MoveFailure.crossDevice {
                // Same device but the rename still crossed a boundary: fall through to the copy path.
            }
        }
        return try copyOnce(&attempt, folder: folder)
    }

    /// Same volume: verify the vault file through the descriptor opened at the start, rename it into place, then
    /// check the entry the rename placed is that very file. A different file found there is moved back.
    private func moveOnce(_ attempt: Attempt, folder: RestoreFolder) throws {
        let vault = vaultPath(attempt.id)
        // The vault copy is the last copy of the content: the restored bytes must be exactly the recorded ones.
        let content = try QuarantineFiles.hash(of: attempt.source)
        guard content.hex == attempt.expected, content.size == attempt.source.info.st_size else {
            throw QuarantineError.changedSinceScan
        }
        hooks.beforeRestoreMove?()
        try folder.moveIn(fromPath: vault, as: attempt.name)
        if let placed = folder.entryInfo(attempt.name), QuarantineFiles.sameFile(placed, attempt.source.info) {
            return
        }
        // The rename took whatever sat at the vault path at that moment, and it is not the verified file.
        do { try folder.moveOut(attempt.name, toPath: vault) } catch {
            let target = attempt.original.deletingLastPathComponent().appendingPathComponent(attempt.name).path
            throw QuarantineError.ioFailure(
                "A file other than the quarantined one ended up at \(target) and could not be moved back. "
                    + "The quarantine record is kept."
            )
        }
        throw QuarantineError.changedSinceScan
    }

    /// Other volume: copy into a new partial, verify the bytes written, rename the partial into place, and only
    /// discard the vault copy once the entry the rename placed is the very file that was copied.
    private func copyOnce(_ attempt: inout Attempt, folder: RestoreFolder) throws -> stat {
        let id = attempt.id
        let partial = ".\(id.uuidString).partial"
        // A restore that crashed earlier can have left our partial behind; clear it so O_EXCL can create it again.
        QuarantineRemoval.discard(.restorePartial(folder: folder.path, id: id))
        let copied = try QuarantineFiles.copy(attempt.source, into: folder.descriptor, name: partial) {
            attempt.createdPartial = true
        }
        // The vault copy is the last copy of the content: the restored bytes must be exactly the recorded ones.
        guard copied.hex == attempt.expected, copied.size == attempt.source.info.st_size else {
            throw QuarantineError.changedSinceScan
        }
        let target = attempt.original.deletingLastPathComponent().appendingPathComponent(attempt.name)
        hooks.beforeRestoreRename?(target.path)
        try folder.rename(partial, to: attempt.name)
        guard let placed = folder.entryInfo(attempt.name), Self.isCopy(placed, of: copied) else {
            // The rename placed some other file: it is not ours, and neither is whatever now has our partial's
            // name. Remove nothing and keep the vault copy.
            attempt.createdPartial = false
            throw QuarantineError.changedSinceScan
        }
        // The restored copy is in place and verified; failing to remove our own quarantined copy loses nothing.
        QuarantineRemoval.discard(.vaultCopy(vault: directory, id: id))
        return copied.info
    }

    /// The entry is the regular file `copy` created (same device and inode) and holds as many bytes as were written.
    private static func isCopy(_ entry: stat, of copy: QuarantineFiles.CopyResult) -> Bool {
        entry.st_mode & S_IFMT == S_IFREG && entry.st_dev == copy.info.st_dev && entry.st_ino == copy.info.st_ino
            && entry.st_size == copy.size
    }

    /// `a.txt` -> `a (restored).txt`, then `a (restored 2).txt`, ...: the first name nothing occupies in `folder`.
    private func freeName(for original: String, in folder: RestoreFolder) -> String {
        if folder.entryInfo(original) == nil {
            return original
        }
        let name = original as NSString
        let ext = name.pathExtension
        let stem = name.deletingPathExtension
        var attempt = 1
        while true {
            let marker = attempt == 1 ? " (restored)" : " (restored \(attempt))"
            let candidate = stem + marker + (ext.isEmpty ? "" : "." + ext)
            if folder.entryInfo(candidate) == nil {
                return candidate
            }
            attempt += 1
        }
    }
}
