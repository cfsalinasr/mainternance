import Darwin
import Foundation
import MainternanceDomain

/// The ONE place the quarantine code removes anything from disk. Nothing else in the quarantine calls
/// `removeItem`, `unlink` or `rm`.
///
/// Why this is not a move to the Trash: quarantine is itself the safe place. Moving a file into quarantine across
/// volumes is "copy, verify the copy's hash, then remove the original", which is a move, not a deletion of user data,
/// and leftovers of the app's own bookkeeping (sidecars, half-written copies) are not user files. Every removal here
/// is one of these four cases, and each is checked before anything is removed:
/// - `.vaultArtifact`: a sidecar `<uuid>.json` or a half-written `*.partial` directly inside the quarantine folder.
/// - `.vaultCopy`: the app's copy `<uuid>` in the quarantine folder, only after the file verifiably exists elsewhere
///   (the original is still in place after a failed quarantine, or the restored copy is in place after a restore).
/// - `.restorePartial`: the half-written `.<uuid>.partial` a restore created next to its target.
/// - `.verifiedOriginal`: the original after its hash-verified copy was renamed into the quarantine folder.
///
/// The name is checked first (one plain name, never a path, matching the case's pattern). The folder is opened once
/// and the entry is checked and removed relative to that open folder (`fstatat` + `unlinkat`), so swapping a parent
/// folder cannot redirect the removal; symlinks are never followed and must be a regular file. For the original, the
/// opened folder must also be the very folder (same device and inode) that was resolved and checked against
/// `ProtectedPaths` before the file was hashed.
///
/// Residual race, accepted: between the `fstatat` check and the `unlinkat` inside that one folder, a process that can
/// write to that folder could rename another file to the same name. Such a process can already delete that file
/// itself, so this gives it nothing new.
enum QuarantineRemoval {
    enum Target {
        case vaultArtifact(vault: URL, name: String)
        case vaultCopy(vault: URL, id: UUID)
        case restorePartial(folder: String, id: UUID)
        case verifiedOriginal(folder: String, folderIdentity: stat, name: String, file: stat)
    }

    private struct Plan {
        let folder: String
        let name: String
        /// Refuse a symlink as the folder itself and require this folder identity.
        let folderIdentity: stat?
        /// Accepts the `lstat` of the entry about to be removed.
        let accepts: (stat) -> Bool
        /// A missing entry counts as done (bookkeeping) instead of an error (the original).
        let missingIsDone: Bool
    }

    /// Removes the target or throws without removing anything. A missing bookkeeping file is not an error.
    static func remove(_ target: Target) throws {
        guard let plan = plan(for: target) else {
            throw QuarantineError.ioFailure("Refused to remove an item the quarantine does not own.")
        }
        let flags = O_RDONLY | O_DIRECTORY | O_CLOEXEC | (plan.folderIdentity == nil ? 0 : O_NOFOLLOW)
        let folder = open(plan.folder, flags)
        guard folder >= 0 else { return try settle(errno, plan) }
        defer { _ = close(folder) }
        if let expected = plan.folderIdentity {
            var info = stat()
            guard fstat(folder, &info) == 0, info.st_dev == expected.st_dev, info.st_ino == expected.st_ino else {
                throw QuarantineError.changedSinceScan
            }
        }
        var info = stat()
        guard fstatat(folder, plan.name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { return try settle(errno, plan) }
        guard plan.accepts(info) else { throw QuarantineError.changedSinceScan }
        guard unlinkat(folder, plan.name, 0) == 0 else { return try settle(errno, plan) }
    }

    /// Like `remove`, for cleanup whose failure loses nothing (the item stays and a later load deals with it).
    static func discard(_ target: Target) {
        try? remove(target)
    }

    /// A missing bookkeeping item is already done; a missing original means it changed; anything else is an error.
    private static func settle(_ code: Int32, _ plan: Plan) throws {
        guard code == ENOENT else { throw QuarantineError.ioFailure(QuarantineFiles.message(code)) }
        if !plan.missingIsDone {
            throw QuarantineError.changedSinceScan
        }
    }

    private static func isRegular(_ info: stat) -> Bool {
        info.st_mode & S_IFMT == S_IFREG
    }

    private static func isPlainName(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.contains("/")
    }

    static func isVaultArtifactName(_ name: String) -> Bool {
        guard isPlainName(name) else { return false }
        if name.hasSuffix(".partial") {
            return true
        }
        return name.hasSuffix(".json") && UUID(uuidString: String(name.dropLast(5))) != nil
    }

    private static func plan(for target: Target) -> Plan? {
        switch target {
        case let .vaultArtifact(vault, name):
            guard isVaultArtifactName(name) else { return nil }
            return Plan(folder: vault.path, name: name, folderIdentity: nil, accepts: isRegular, missingIsDone: true)
        case let .vaultCopy(vault, id):
            return Plan(
                folder: vault.path, name: id.uuidString, folderIdentity: nil, accepts: isRegular, missingIsDone: true
            )
        case let .restorePartial(folder, id):
            return Plan(
                folder: folder, name: ".\(id.uuidString).partial", folderIdentity: nil, accepts: isRegular,
                missingIsDone: true
            )
        case let .verifiedOriginal(folder, folderIdentity, name, file):
            guard isPlainName(name) else { return nil }
            return Plan(
                folder: folder, name: name, folderIdentity: folderIdentity,
                accepts: { QuarantineFiles.sameFile($0, file) }, missingIsDone: false
            )
        }
    }
}
