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
/// Residual, accepted and documented:
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
        let placed = try moveOut(id: id, to: original, in: folder)
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
    private func moveOut(id: UUID, to original: URL, in folder: RestoreFolder) throws -> Placed {
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
            do {
                let identity = try moveOutOnce(id: id, source: source, name: name, original: original, folder: folder)
                return Placed(name: name, identity: identity)
            } catch QuarantineFiles.MoveFailure.destinationExists {
                // Something appeared at this name meanwhile: drop our half-written copy (the next try creates it
                // again with O_EXCL) and pick the next free name.
                QuarantineRemoval.discard(.restorePartial(folder: folder.path, id: id))
                continue
            } catch {
                QuarantineRemoval.discard(.restorePartial(folder: folder.path, id: id))
                throw Self.wrap(error)
            }
        }
        throw QuarantineError.ioFailure("No free name was found to restore the file.")
    }

    private func moveOutOnce(
        id: UUID,
        source: QuarantineFiles.OpenFile,
        name: String,
        original: URL,
        folder: RestoreFolder
    ) throws -> stat {
        if !hooks.forceCopy {
            do {
                try folder.moveIn(fromPath: vaultPath(id), as: name)
                return source.info
            } catch QuarantineFiles.MoveFailure.crossDevice {
                // fall through to the copy path
            }
        }
        let partial = ".\(id.uuidString).partial"
        let copied = try QuarantineFiles.copy(source, into: folder.descriptor, name: partial)
        guard copied.size == source.info.st_size else { throw QuarantineError.changedSinceScan }
        hooks.beforeRestoreRename?(original.deletingLastPathComponent().appendingPathComponent(name).path)
        try folder.rename(partial, to: name)
        // The restored copy is in place and verified; failing to remove our own quarantined copy loses nothing.
        QuarantineRemoval.discard(.vaultCopy(vault: directory, id: id))
        return copied.info
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
