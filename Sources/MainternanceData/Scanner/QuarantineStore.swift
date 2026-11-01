import CryptoKit
import Foundation
import MainternanceDomain

/// Quarantine store: moves suspicious files into one app-owned folder and can put them back.
///
/// Layout: `<directory>/<uuid>` holds each quarantined file (mode `0o600`), `<directory>/index.json` the manifest.
/// There is deliberately no API that deletes a quarantined file. All operations run one at a time (actor).
///
/// Crash safety (choice: manifest first): `quarantine` writes the entry as `pending` BEFORE touching the file,
/// then moves it, then marks the entry `stored`. Every later load resolves leftovers, and no step can lose a file:
/// - pending and the vault file exists: the move finished, the entry becomes `stored`;
/// - pending and no vault file: the move never happened, the original is untouched, the entry is dropped;
/// - a cross-volume copy in progress is `<uuid>.partial`; the original is only removed after the verified copy
///   was renamed into place, so a leftover partial file is only a copy and is swept;
/// - stored and no vault file: the file was already restored (crash before the manifest update); entry dropped.
/// A corrupt manifest is moved aside to `index.corrupt-<uuid>.json` (never overwritten, never deleted) and quarantined
/// files are never touched because of it. Files in the vault with no manifest entry stay where they are.
public actor QuarantineStore: QuarantineStoring {
    private let directory: URL
    private let fileManager: FileManager
    private let now: @Sendable () -> Date
    private let isSameVolume: @Sendable (URL, URL) -> Bool

    public init(directory: URL, fileManager: FileManager = .default, now: @escaping @Sendable () -> Date) {
        self.init(directory: directory, fileManager: fileManager, now: now, isSameVolume: Self.sameVolume)
    }

    /// Tests inject `isSameVolume` to exercise the copy-and-verify path without a second disk.
    init(
        directory: URL, fileManager: FileManager = .default, now: @escaping @Sendable () -> Date,
        isSameVolume: @escaping @Sendable (URL, URL) -> Bool
    ) {
        self.directory = directory
        self.fileManager = fileManager
        self.now = now
        self.isSameVolume = isSameVolume
    }

    private var manifestURL: URL {
        directory.appendingPathComponent("index.json")
    }

    // MARK: QuarantineStoring

    public func records() -> [QuarantineRecord] {
        guard let entries = try? loadRecovered().entries else { return [] }
        return entries.filter { $0.state == .stored }.map(\.record)
    }

    public func quarantine(path: String, signature: String) throws -> QuarantineRecord {
        if ProtectedPaths.isProtected(path, including: [directory]) {
            throw QuarantineError.protectedPath
        }
        let attributes = try regularFileAttributes(atPath: path)
        let source = URL(fileURLWithPath: path)
        try ensureDirectory()
        var entries = try loadRecovered().entries
        let digest = try Self.hash(of: source)
        let record = QuarantineRecord(
            id: UUID(), originalPath: path, quarantinedAt: Self.wholeSeconds(now()), signature: signature,
            sha256: digest.hex, size: digest.size, originalPermissions: Self.permissionBits(attributes)
        )
        let stored = directory.appendingPathComponent(record.id.uuidString)
        entries.append(.init(state: .pending, record: record))
        try write(entries)
        do {
            try transfer(from: source, to: stored, partial: partialURL(for: record.id), expectedSHA256: digest.hex)
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: stored.path)
        } catch {
            try? rollbackQuarantine(record, stored: stored)
            throw Self.wrap(error)
        }
        entries[entries.count - 1].state = .stored
        // If this write fails the entry stays `pending` and the next load promotes it: the file is not lost.
        try? write(entries)
        return record
    }

    public func restore(_ id: UUID) throws -> String {
        var entries = try loadRecovered().entries
        guard let index = entries.firstIndex(where: { $0.state == .stored && $0.record.id == id }) else {
            throw QuarantineError.missing
        }
        let record = entries[index].record
        let stored = directory.appendingPathComponent(id.uuidString)
        guard fileManager.fileExists(atPath: stored.path) else { throw QuarantineError.missing }
        let original = URL(fileURLWithPath: record.originalPath)
        var isFolder: ObjCBool = false
        guard fileManager.fileExists(atPath: original.deletingLastPathComponent().path, isDirectory: &isFolder),
              isFolder.boolValue else { throw QuarantineError.restoreTargetMissing }
        let target = freeTarget(for: original)
        let partial = target.deletingLastPathComponent().appendingPathComponent(".\(id.uuidString).partial")
        do {
            try transfer(from: stored, to: target, partial: partial, expectedSHA256: nil)
            entries.remove(at: index)
            try? write(entries)
            try fileManager.setAttributes([.posixPermissions: record.originalPermissions], ofItemAtPath: target.path)
        } catch {
            throw Self.wrap(error)
        }
        return target.path
    }

    // MARK: Moving files

    /// Moves `source` to `destination` without ever overwriting. Same volume: one atomic rename. Otherwise: copy to
    /// `partial`,
    /// verify the content hash, rename into place, and only then remove the source.
    private func transfer(
        from source: URL, to destination: URL, partial: URL, expectedSHA256: String?
    ) throws {
        if isSameVolume(source, destination.deletingLastPathComponent()) {
            try fileManager.moveItem(at: source, to: destination)
            return
        }
        let expected = try expectedSHA256 ?? Self.hash(of: source).hex
        try? fileManager.removeItem(at: partial)
        do {
            try fileManager.copyItem(at: source, to: partial)
            guard try Self.hash(of: partial).hex == expected else {
                throw QuarantineError.ioFailure("The copy did not match the original, so nothing was moved.")
            }
            try fileManager.moveItem(at: partial, to: destination)
        } catch {
            try? fileManager.removeItem(at: partial)
            throw error
        }
        do {
            try fileManager.removeItem(at: source)
        } catch {
            try? fileManager.removeItem(at: destination)
            throw error
        }
    }

    /// Puts the file back after a failed quarantine and drops the pending entry.
    private func rollbackQuarantine(_ record: QuarantineRecord, stored: URL) throws {
        let original = URL(fileURLWithPath: record.originalPath)
        if fileManager.fileExists(atPath: stored.path), !exists(original) {
            try fileManager.moveItem(at: stored, to: original)
            try fileManager.setAttributes([.posixPermissions: record.originalPermissions], ofItemAtPath: original.path)
        }
        guard !fileManager.fileExists(atPath: stored.path) else { return } // keep the pending entry: file is safe
        var entries = try loadRecovered().entries
        entries.removeAll { $0.record.id == record.id }
        try write(entries)
    }

    /// `a.txt` -> `a (restored).txt`, then `a (restored 2).txt`, ...: the first name nothing occupies.
    private func freeTarget(for original: URL) -> URL {
        if !exists(original) {
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
            if !exists(candidate) {
                return candidate
            }
            attempt += 1
        }
    }

    // MARK: Manifest

    /// Loads the manifest and resolves what a crash may have left behind (see the type comment). Persists the
    /// cleanup when anything changed. A corrupt manifest reads as empty; it is kept aside on the next write.
    private func loadRecovered() throws -> (entries: [QuarantineManifest.Entry], corrupt: Bool) {
        guard let data = try? Data(contentsOf: manifestURL) else {
            sweepPartials()
            return ([], false)
        }
        guard let loaded = try? QuarantineManifest.decode(data) else { return ([], true) }
        var changed = sweepPartials()
        var entries: [QuarantineManifest.Entry] = []
        for var entry in loaded {
            let present = fileManager
                .fileExists(atPath: directory.appendingPathComponent(entry.record.id.uuidString).path)
            if !present {
                changed = true
                continue
            }
            if entry.state == .pending {
                entry.state = .stored
                changed = true
            }
            entries.append(entry)
        }
        if changed {
            try? write(entries)
        }
        return (entries, false)
    }

    @discardableResult
    private func sweepPartials() -> Bool {
        let names = (try? fileManager.contentsOfDirectory(atPath: directory.path)) ?? []
        var removed = false
        for name in names where name.hasSuffix(".partial") {
            try? fileManager.removeItem(at: directory.appendingPathComponent(name))
            removed = true
        }
        return removed
    }

    /// Atomic write. An unreadable existing manifest is first renamed to `index.corrupt-<uuid>.json`.
    private func write(_ entries: [QuarantineManifest.Entry]) throws {
        try ensureDirectory()
        if let data = try? Data(contentsOf: manifestURL), (try? QuarantineManifest.decode(data)) == nil {
            let aside = directory.appendingPathComponent("index.corrupt-\(UUID().uuidString).json")
            try fileManager.moveItem(at: manifestURL, to: aside)
        }
        try QuarantineManifest.encode(entries).write(to: manifestURL, options: .atomic)
    }

    // MARK: Helpers

    private func ensureDirectory() throws {
        do {
            try fileManager.createDirectory(
                at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
            )
        } catch {
            throw Self.wrap(error)
        }
    }

    private func partialURL(for id: UUID) -> URL {
        directory.appendingPathComponent("\(id.uuidString).partial")
    }

    /// `lstat`-based: a dangling symlink still counts as occupied.
    private func exists(_ url: URL) -> Bool {
        (try? fileManager.attributesOfItem(atPath: url.path)) != nil
    }

    private func regularFileAttributes(atPath path: String) throws -> [FileAttributeKey: Any] {
        guard let attributes = try? fileManager.attributesOfItem(atPath: path) else { throw QuarantineError.missing }
        guard (attributes[.type] as? FileAttributeType) == .typeRegular else { throw QuarantineError.notRegularFile }
        return attributes
    }

    private static func permissionBits(_ attributes: [FileAttributeKey: Any]) -> Int {
        ((attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0o600) & 0o7777
    }

    /// The manifest stores seconds as JSON numbers; whole seconds round-trip exactly, so the record handed back
    /// equals the one read from disk later.
    private static func wholeSeconds(_ date: Date) -> Date {
        Date(timeIntervalSince1970: date.timeIntervalSince1970.rounded(.down))
    }

    private static func wrap(_ error: Error) -> QuarantineError {
        (error as? QuarantineError) ?? .ioFailure(error.localizedDescription)
    }

    private static let sameVolume: @Sendable (URL, URL) -> Bool = { first, second in
        let keys: Set<URLResourceKey> = [.volumeIdentifierKey]
        guard let one = try? first.resourceValues(forKeys: keys).volumeIdentifier as? NSObject,
              let two = try? second.resourceValues(forKeys: keys).volumeIdentifier as? NSObject else { return false }
        return one.isEqual(two)
    }

    /// SHA-256 and size, streamed in 1 MiB chunks so large files never sit in memory.
    static func hash(of url: URL) throws -> (hex: String, size: Int64) {
        let handle: FileHandle
        do { handle = try FileHandle(forReadingFrom: url) } catch { throw wrap(error) }
        defer { try? handle.close() }
        var hasher = SHA256()
        var size: Int64 = 0
        do {
            while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
                hasher.update(data: chunk)
                size += Int64(chunk.count)
            }
        } catch { throw wrap(error) }
        return (hex(hasher.finalize()), size)
    }

    static func sha256Hex(of data: Data) -> String {
        hex(SHA256.hash(data: data))
    }

    private static func hex(_ digest: SHA256.Digest) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}
