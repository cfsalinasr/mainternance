import Darwin
import Foundation
import MainternanceDomain

/// Quarantine store: moves suspicious files into one app-owned folder and can put them back.
///
/// Layout: `<directory>/<uuid>` holds each quarantined file (mode `0o600`), `<directory>/<uuid>.json` is its sidecar
/// (the full record) and `<directory>/index.json` the manifest. There is deliberately no API that deletes a
/// quarantined file. All operations run one at a time (actor). Every removal from disk (the original after a verified
/// cross-volume copy, and the store's own bookkeeping) goes through `QuarantineRemoval`, which checks it first.
///
/// Crash safety (choice: sidecar and manifest first). `quarantine` writes the sidecar, then the manifest entry as
/// `pending`, BEFORE touching the file, then moves it, then marks the entry `stored`. Every load resolves leftovers
/// (see `QuarantineStore+Recovery.swift`) and no step can lose a file. The manifest can be lost or corrupted: it is
/// then rebuilt from the sidecars and the damaged file is kept aside as `index.corrupt-<uuid>.json`. A manifest that
/// merely cannot be read (permissions, I/O) is never replaced: operations fail with `.ioFailure` and write nothing.
///
/// Race safety: the source is opened once with `O_NOFOLLOW`; type, size and hash come from that descriptor; the
/// physical parent folder is compared before and after and re-checked against `ProtectedPaths` right before the move;
/// the move never overwrites (`RENAME_EXCL`); the moved item must be the very same file; permissions are applied with
/// `fchmod` on a descriptor. A restore is bound to its checked destination folder (see
/// `QuarantineStore+Restore.swift`).
public actor QuarantineStore: QuarantineStoring {
    /// Test seams. Production code uses the defaults.
    struct Hooks: Sendable {
        /// Behave as if the quarantine folder were on another volume (copy, verify, then remove the original).
        var forceCopy = false
        /// Runs after the file was hashed and before it moves; tests swap files or folders here.
        var beforeMove: (@Sendable () -> Void)?
        /// Makes the permission reset after a restore fail.
        var failRestorePermissions = false
        /// Runs in the copy path of a restore right before the copy is renamed to `target`.
        var beforeRestoreRename: (@Sendable (String) -> Void)?
        /// Runs in the copy path of a quarantine after the verified copy is in the vault, before the original goes.
        var beforeOriginalRemoval: (@Sendable () -> Void)?
        /// Runs in a restore after the destination folder was resolved and checked, before it is opened.
        var beforeRestoreFolderOpen: (@Sendable () -> Void)?
        /// Runs in a restore after the destination folder was opened and checked, before anything is written to it.
        var afterRestoreFolderOpen: (@Sendable () -> Void)?
    }

    let directory: URL
    let fileManager: FileManager
    let now: @Sendable () -> Date
    let hooks: Hooks

    public init(directory: URL, fileManager: FileManager = .default, now: @escaping @Sendable () -> Date) {
        self.init(directory: directory, fileManager: fileManager, now: now, hooks: Hooks())
    }

    init(directory: URL, fileManager: FileManager = .default, now: @escaping @Sendable () -> Date, hooks: Hooks) {
        self.directory = directory
        self.fileManager = fileManager
        self.now = now
        self.hooks = hooks
    }

    // MARK: QuarantineStoring

    public func records() -> [QuarantineRecord] {
        guard let entries = try? load() else { return [] }
        return entries.filter { $0.state == .stored }.map(\.record)
    }

    public func quarantine(path: String, signature: String) throws -> QuarantineRecord {
        if ProtectedPaths.isProtected(path, including: [directory]) {
            throw QuarantineError.protectedPath
        }
        let name = (path as NSString).lastPathComponent
        let parent = try QuarantineFiles.realParent(of: path)
        if ProtectedPaths.isProtected(parent + "/" + name, including: [directory]) {
            throw QuarantineError.protectedPath
        }
        let origin = try Origin(path: path, folder: parent, folderIdentity: QuarantineFiles.folderIdentity(parent))
        let file = try QuarantineFiles.openRegular(path)
        defer { file.close() }
        try ensureDirectory()
        var entries = try load()
        let digest = try QuarantineFiles.hash(of: file)
        let record = QuarantineRecord(
            id: UUID(), originalPath: path, quarantinedAt: Self.wholeSeconds(now()), signature: signature,
            sha256: digest.hex, size: digest.size, originalPermissions: Int(file.info.st_mode) & 0o7777
        )
        try writeSidecar(record)
        entries.append(.init(state: .pending, record: record))
        do { try write(entries) } catch {
            removeSidecar(record.id)
            throw error
        }
        let stored = vaultPath(record.id)
        do {
            hooks.beforeMove?()
            try verifyPlace(of: path, parent: parent)
            try moveIn(origin, file: file, stored: stored, expected: digest)
            try QuarantineFiles.setPermissions(0o600, atPath: stored, expecting: QuarantineFiles.linkInfo(stored))
        } catch {
            rollbackQuarantine(record, stored: stored)
            throw Self.wrap(error)
        }
        entries[entries.count - 1].state = .stored
        // If this write fails the entry stays `pending` and the next load promotes it: the file is not lost.
        try? write(entries)
        return record
    }

    /// Items in the quarantine folder that no record describes (no sidecar and no manifest entry). They are never
    /// touched or deleted; this only reports them so the app can say so.
    public func unclaimedFiles() -> [String] {
        guard let entries = try? load() else { return [] }
        let known = Set(entries.map(\.record.id))
        let names = (try? fileManager.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.filter { UUID(uuidString: $0).map { !known.contains($0) } ?? false }.sorted()
    }

    /// Records whose copy is in quarantine but whose original also still sits at its path with the same content
    /// (a copy across volumes was interrupted before the original was removed). They are NOT listed in `records()`
    /// as contained; nothing is deleted, and the original stays where it is.
    public func stillInPlace() -> [QuarantineRecord] {
        guard let entries = try? load() else { return [] }
        return entries.filter { $0.state == .pending }.map(\.record)
    }

    // MARK: Moving files

    private func verifyPlace(of path: String, parent: String) throws {
        guard let again = try? QuarantineFiles.realParent(of: path), again == parent else {
            throw QuarantineError.changedSinceScan
        }
        if ProtectedPaths.isProtected(again + "/" + (path as NSString).lastPathComponent, including: [directory]) {
            throw QuarantineError.protectedPath
        }
    }

    /// Where the file to quarantine sits: the path as given, and its physical folder as checked against
    /// `ProtectedPaths` (with the folder's device and inode, so a later swap of that folder is detected).
    struct Origin {
        let path: String
        let folder: String
        let folderIdentity: stat

        var name: String {
            (path as NSString).lastPathComponent
        }
    }

    /// Same volume: one atomic no-overwrite rename, then the moved item must be the file that was opened (a symlink
    /// swapped in meanwhile fails this check and is moved back by the rollback). Across volumes: copy the open
    /// descriptor, verify, rename into place, and remove the original only if it still is that file in that folder.
    private func moveIn(
        _ origin: Origin,
        file: QuarantineFiles.OpenFile,
        stored: String,
        expected: (hex: String, size: Int64)
    ) throws {
        let path = origin.path
        if !hooks.forceCopy {
            do {
                try QuarantineFiles.renameNoOverwrite(path, to: stored)
                guard let moved = QuarantineFiles.linkInfo(stored), QuarantineFiles.sameFile(moved, file.info) else {
                    throw QuarantineError.changedSinceScan
                }
                return
            } catch QuarantineFiles.MoveFailure.crossDevice {
                // fall through to the copy path
            }
        }
        let partialName = (stored as NSString).lastPathComponent + ".partial"
        let partial = directory.appendingPathComponent(partialName).path
        QuarantineRemoval.discard(.vaultArtifact(vault: directory, name: partialName))
        do {
            let copied = try QuarantineFiles.copy(file, toNewFile: partial)
            guard copied == expected else { throw QuarantineError.changedSinceScan }
            try QuarantineFiles.renameNoOverwrite(partial, to: stored)
        } catch {
            QuarantineRemoval.discard(.vaultArtifact(vault: directory, name: partialName))
            throw Self.wrap(error)
        }
        hooks.beforeOriginalRemoval?()
        do {
            try QuarantineRemoval.remove(.verifiedOriginal(
                folder: origin.folder, folderIdentity: origin.folderIdentity, name: origin.name, file: file.info
            ))
        } catch {
            // Keep our verified copy in every failure case. No check of the original is atomic with removing the
            // copy: the original may have been replaced meanwhile, leaving the copy as the only one of the old
            // content. The rollback leaves the entry `pending` while something sits at the original path, and the
            // next load makes it `pending` (original still has the recorded content) or `stored` (it changed).
            throw Self.wrap(error)
        }
    }

    /// Puts the file back after a failed quarantine and drops its sidecar and entry. If the file cannot be put
    /// back (for example because something sits at the original path), the copy, sidecar and `pending` entry stay in
    /// place: the next load resolves them, and the file is never lost.
    private func rollbackQuarantine(_ record: QuarantineRecord, stored: String) {
        let original = record.originalPath
        if QuarantineFiles.linkInfo(stored) != nil {
            guard QuarantineFiles.linkInfo(original) == nil,
                  (try? QuarantineFiles.renameNoOverwrite(stored, to: original)) != nil else { return }
            try? QuarantineFiles.setPermissions(record.originalPermissions, atPath: original)
        }
        removeSidecar(record.id)
        if var entries = try? load() {
            entries.removeAll { $0.record.id == record.id }
            try? write(entries)
        }
    }

    // MARK: Helpers

    func vaultPath(_ id: UUID) -> String {
        directory.appendingPathComponent(id.uuidString).path
    }

    func sidecarURL(_ id: UUID) -> URL {
        directory.appendingPathComponent("\(id.uuidString).json")
    }

    func ensureDirectory() throws {
        do {
            try fileManager.createDirectory(
                at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
            )
        } catch {
            throw Self.wrap(error)
        }
    }

    /// The manifest stores seconds as JSON numbers; whole seconds round-trip exactly, so the record handed back
    /// equals the one read from disk later.
    private static func wholeSeconds(_ date: Date) -> Date {
        Date(timeIntervalSince1970: date.timeIntervalSince1970.rounded(.down))
    }

    static func wrap(_ error: Error) -> QuarantineError {
        (error as? QuarantineError) ?? .ioFailure(error.localizedDescription)
    }
}
