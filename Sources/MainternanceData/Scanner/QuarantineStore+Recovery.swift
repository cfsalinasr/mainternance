import Foundation
import MainternanceDomain

/// Loading, crash recovery and writing of the manifest and the sidecars.
///
/// What a load resolves (`pending` is written before a move; `stored` after it):
/// - manifest entry and the item exists in the vault: `pending` becomes `stored`, unless the original path still
///   holds a file with the same hash (an interrupted cross-volume copy). That entry stays `pending`: it is not
///   reported as contained (`stillInPlace()`), the vault copy is kept, nothing is deleted.
/// - entry but no vault item: the move never happened (pending) or the restore already happened (stored); the
///   entry and its sidecar are dropped.
/// - sidecar and vault item but no entry (manifest lost, corrupt, or its write failed): the entry is rebuilt.
/// - sidecar without vault item and without entry: stale metadata of a move that never happened; removed.
/// - `*.partial` copies in the vault are leftovers of an interrupted copy; the original is only removed after the
///   verified copy was renamed into place, so they are swept.
/// - vault items without sidecar or entry stay untouched and are reported by `unclaimedFiles()`.
extension QuarantineStore {
    enum ManifestState {
        case missing
        case entries([QuarantineManifest.Entry])
        case corrupt
    }

    private var manifestURL: URL {
        directory.appendingPathComponent("index.json")
    }

    /// Only a truly missing file is `.missing`; any other read failure throws `.ioFailure` and nothing is written.
    func readManifest() throws -> ManifestState {
        let data: Data
        do { data = try Data(contentsOf: manifestURL) } catch {
            if QuarantineFiles.isNoSuchFile(error) {
                return .missing
            }
            throw QuarantineError.ioFailure(error.localizedDescription)
        }
        guard let entries = try? QuarantineManifest.decode(data) else { return .corrupt }
        return .entries(entries)
    }

    func load() throws -> [QuarantineManifest.Entry] {
        var isFolder: ObjCBool = false
        guard fileManager.fileExists(atPath: directory.path, isDirectory: &isFolder),
              isFolder.boolValue else { return [] }
        let state = try readManifest()
        var changed = sweepPartials()
        var fromManifest: [QuarantineManifest.Entry] = []
        switch state {
        case let .entries(list): fromManifest = list
        case .corrupt: changed = true // the rewrite moves the damaged file aside
        case .missing: break
        }
        var entries: [QuarantineManifest.Entry] = []
        for var entry in fromManifest {
            guard vaultItemExists(entry.record.id) else {
                removeSidecar(entry.record.id)
                changed = true
                continue
            }
            if entry.state == .pending {
                entry.state = classify(entry.record)
                changed = changed || entry.state == .stored
            }
            entries.append(entry)
        }
        let known = Set(entries.map(\.record.id))
        for record in readSidecars() where !known.contains(record.id) {
            guard vaultItemExists(record.id) else {
                removeSidecar(record.id)
                continue
            }
            entries.append(.init(state: classify(record), record: record))
            changed = true
        }
        if changed {
            try? write(entries)
        }
        return entries
    }

    /// Writes the manifest atomically. An existing manifest that is corrupt, or that cannot even be read, is first
    /// renamed to `index.corrupt-<uuid>.json`; it is never overwritten.
    func write(_ entries: [QuarantineManifest.Entry]) throws {
        try ensureDirectory()
        do {
            let current = try? readManifest()
            if current == nil || current.map(Self.isCorrupt) == true {
                let aside = directory.appendingPathComponent("index.corrupt-\(UUID().uuidString).json")
                try fileManager.moveItem(at: manifestURL, to: aside)
            }
            try QuarantineManifest.encode(entries).write(to: manifestURL, options: .atomic)
        } catch {
            throw Self.wrap(error)
        }
    }

    private static func isCorrupt(_ state: ManifestState) -> Bool {
        if case .corrupt = state {
            return true
        }
        return false
    }

    func writeSidecar(_ record: QuarantineRecord) throws {
        do {
            try QuarantineManifest.encodeRecord(record).write(to: sidecarURL(record.id), options: .atomic)
        } catch {
            throw Self.wrap(error)
        }
    }

    func removeSidecar(_ id: UUID) {
        try? fileManager.removeItem(at: sidecarURL(id))
    }

    private func readSidecars() -> [QuarantineRecord] {
        let names = (try? fileManager.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.sorted().compactMap { name in
            guard name.hasSuffix(".json"), let id = UUID(uuidString: String(name.dropLast(5))),
                  let data = try? Data(contentsOf: directory.appendingPathComponent(name)),
                  let record = try? QuarantineManifest.decodeRecord(data), record.id == id else { return nil }
            return record
        }
    }

    private func vaultItemExists(_ id: UUID) -> Bool {
        QuarantineFiles.linkInfo(vaultPath(id)) != nil
    }

    /// `.stored`, unless the original still sits at its path with the recorded content (interrupted copy).
    private func classify(_ record: QuarantineRecord) -> QuarantineManifest.State {
        QuarantineFiles.hash(ofPath: record.originalPath) == record.sha256 ? .pending : .stored
    }

    private func sweepPartials() -> Bool {
        let names = (try? fileManager.contentsOfDirectory(atPath: directory.path)) ?? []
        var removed = false
        for name in names where name.hasSuffix(".partial") {
            try? fileManager.removeItem(at: directory.appendingPathComponent(name))
            removed = true
        }
        return removed
    }
}
