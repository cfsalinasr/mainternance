import Darwin
import Foundation
import MainternanceDomain

/// Quarantine store: moves suspicious files into one app-owned folder and can put them back.
///
/// Layout: `<directory>/<uuid>` holds each quarantined file (mode `0o600`), `<directory>/<uuid>.json` is its sidecar
/// (the full record) and `<directory>/index.json` the manifest. There is deliberately no API that deletes a
/// quarantined file. All operations run one at a time (actor).
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
/// `fchmod` on a descriptor.
public actor QuarantineStore: QuarantineStoring {
    /// Test seams. Production code uses the defaults.
    struct Hooks: Sendable {
        /// Behave as if the quarantine folder were on another volume (copy, verify, then remove the original).
        var forceCopy = false
        /// Runs after the file was hashed and before it moves; tests swap files or folders here.
        var beforeMove: (@Sendable () -> Void)?
        /// Makes the permission reset after a restore fail.
        var failRestorePermissions = false
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
            try moveIn(path: path, file: file, stored: stored, expected: digest)
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

    /// Restores the file and returns the path it really went to (`a (restored).txt` when something is in the way).
    /// A failed permission reset after the move does not fail the restore: the file is back, and keeps the
    /// quarantine's `0o600` until the permissions are fixed by hand. Special bits (setuid, sticky) are never restored.
    public func restore(_ id: UUID) throws -> String {
        var entries = try load()
        guard let index = entries.firstIndex(where: { $0.state == .stored && $0.record.id == id }) else {
            throw QuarantineError.missing
        }
        let record = entries[index].record
        let original = URL(fileURLWithPath: record.originalPath)
        let blocked = ProtectedPaths.isProtected(record.originalPath, including: [directory])
        guard !blocked else { throw QuarantineError.protectedPath }
        var isFolder: ObjCBool = false
        guard fileManager.fileExists(atPath: original.deletingLastPathComponent().path, isDirectory: &isFolder),
              isFolder.boolValue else { throw QuarantineError.restoreTargetMissing }
        let target = try moveOut(id: id, to: original)
        entries.remove(at: index)
        try? write(entries)
        removeSidecar(id)
        if hooks.failRestorePermissions {
            return target
        }
        try? QuarantineFiles.setPermissions(record.originalPermissions, atPath: target)
        return target
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

    /// Same volume: one atomic no-overwrite rename, then the moved item must be the file that was opened (a symlink
    /// swapped in meanwhile fails this check and is moved back by the rollback). Across volumes: copy the open
    /// descriptor, verify, rename into place, and remove the original only if the path still is that file.
    private func moveIn(
        path: String,
        file: QuarantineFiles.OpenFile,
        stored: String,
        expected: (hex: String, size: Int64)
    ) throws {
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
        let partial = stored + ".partial"
        try? fileManager.removeItem(atPath: partial)
        do {
            let copied = try QuarantineFiles.copy(file, toNewFile: partial)
            guard copied == expected else { throw QuarantineError.changedSinceScan }
            try QuarantineFiles.renameNoOverwrite(partial, to: stored)
        } catch {
            try? fileManager.removeItem(atPath: partial)
            throw Self.wrap(error)
        }
        guard let current = QuarantineFiles.linkInfo(path), QuarantineFiles.sameFile(current, file.info) else {
            try? fileManager.removeItem(atPath: stored)
            throw QuarantineError.changedSinceScan
        }
        guard unlink(path) == 0 else {
            let message = QuarantineFiles.message(errno)
            try? fileManager.removeItem(atPath: stored)
            throw QuarantineError.ioFailure(message)
        }
    }

    /// Puts the file back after a failed quarantine and drops its sidecar and entry. If the file cannot be put
    /// back, everything stays in place: the next load resolves it, and the file is never lost.
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

    /// Moves the quarantined item back next to `original`, never overwriting; returns the final path.
    private func moveOut(id: UUID, to original: URL) throws -> String {
        let stored = vaultPath(id)
        let source: QuarantineFiles.OpenFile
        do { source = try QuarantineFiles.openRegular(stored) } catch QuarantineError.notRegularFile {
            throw QuarantineError.ioFailure("The quarantined item is not a regular file, so nothing was restored.")
        }
        defer { source.close() }
        for _ in 0 ..< 8 {
            let target = freeTarget(for: original)
            if ProtectedPaths.isProtected(target.path, including: [directory]) {
                throw QuarantineError.protectedPath
            }
            let partial = target.deletingLastPathComponent().appendingPathComponent(".\(id.uuidString).partial").path
            do {
                try moveOutOnce(stored: stored, source: source, target: target.path, partial: partial)
                return target.path
            } catch QuarantineFiles.MoveFailure.destinationExists {
                continue // something appeared at this name meanwhile: pick the next free one
            } catch {
                try? fileManager.removeItem(atPath: partial)
                throw Self.wrap(error)
            }
        }
        throw QuarantineError.ioFailure("No free name was found to restore the file.")
    }

    private func moveOutOnce(stored: String, source: QuarantineFiles.OpenFile, target: String, partial: String) throws {
        if !hooks.forceCopy {
            do {
                try QuarantineFiles.renameNoOverwrite(stored, to: target)
                return
            } catch QuarantineFiles.MoveFailure.crossDevice {
                // fall through to the copy path
            }
        }
        let copied = try QuarantineFiles.copy(source, toNewFile: partial)
        guard copied.size == source.info.st_size else { throw QuarantineError.changedSinceScan }
        try QuarantineFiles.renameNoOverwrite(partial, to: target)
        // The restored copy is in place and verified; failing to remove our own quarantined copy loses nothing.
        _ = unlink(stored)
    }

    /// `a.txt` -> `a (restored).txt`, then `a (restored 2).txt`, ...: the first name nothing occupies.
    private func freeTarget(for original: URL) -> URL {
        if QuarantineFiles.linkInfo(original.path) == nil {
            return original
        }
        let folder = original.deletingLastPathComponent()
        let name = original.lastPathComponent as NSString
        let ext = name.pathExtension
        let stem = name.deletingPathExtension
        var attempt = 1
        while true {
            let marker = attempt == 1 ? " (restored)" : " (restored \(attempt))"
            let candidate = folder.appendingPathComponent(stem + marker + (ext.isEmpty ? "" : "." + ext))
            if QuarantineFiles.linkInfo(candidate.path) == nil {
                return candidate
            }
            attempt += 1
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
