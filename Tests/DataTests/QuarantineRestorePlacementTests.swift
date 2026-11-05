import Foundation
@testable import MainternanceData
import MainternanceDomain
import Testing

private func names(_ url: URL) -> [String] {
    ((try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []).sorted()
}

private func text(_ url: URL) -> String? {
    try? String(contentsOf: url, encoding: .utf8)
}

/// Overwrites the start of the file in place (same inode, same size).
private func overwrite(_ url: URL, with text: String) {
    guard let handle = try? FileHandle(forWritingTo: url) else { return }
    try? handle.write(contentsOf: Data(text.utf8))
    try? handle.close()
}

/// Moves the entry at `url` aside to `aside` and puts a different file (a new inode) with `content` in its place.
private func swap(_ url: URL, aside: URL, with content: String) {
    try? FileManager.default.moveItem(at: url, to: aside)
    try? Data(content.utf8).write(to: url)
}

@Suite("Quarantine restore, the placed file is the verified one")
struct QuarantineRestorePlacementTests {
    @Test("same volume: a vault copy altered with the same size is not moved, and vault copy and record stay")
    func moveRejectsAlteredVaultCopy() async throws {
        let fix = try QuarantineFixture()
        let file = try fix.makeFile("a.txt", "mine")
        let vault = fix.vault
        let holder = IDHolder()
        var hooks = QuarantineStore.Hooks()
        hooks.afterRestoreFolderOpen = {
            if let id = holder.id {
                overwrite(vault.appendingPathComponent(id.uuidString), with: "evil")
            }
        }
        let store = QuarantineStore(directory: fix.vault, now: { Date() }, hooks: hooks)
        let record = try await store.quarantine(path: file.path, signature: "S")
        holder.id = record.id
        await #expect(throws: QuarantineError.changedSinceScan) { try await store.restore(record.id) }
        #expect(names(fix.area).isEmpty)
        #expect(text(fix.vault.appendingPathComponent(record.id.uuidString)) == "evil")
        #expect(try await store.records() == [record])
    }

    @Test("same volume: a vault entry swapped after the check is moved back, and nothing stays at the destination")
    func moveRejectsSwappedVaultEntry() async throws {
        let fix = try QuarantineFixture()
        let file = try fix.makeFile("a.txt", "mine")
        let vault = fix.vault
        let holder = IDHolder()
        var hooks = QuarantineStore.Hooks()
        // Same content, different file: only the identity check after the move can tell.
        hooks.beforeRestoreMove = {
            if let id = holder.id {
                let entry = vault.appendingPathComponent(id.uuidString)
                swap(entry, aside: vault.appendingPathComponent("stolen"), with: "mine")
            }
        }
        let store = QuarantineStore(directory: fix.vault, now: { Date() }, hooks: hooks)
        let record = try await store.quarantine(path: file.path, signature: "S")
        holder.id = record.id
        await #expect(throws: QuarantineError.changedSinceScan) { try await store.restore(record.id) }
        #expect(names(fix.area).isEmpty)
        #expect(text(fix.vault.appendingPathComponent(record.id.uuidString)) == "mine")
        #expect(text(fix.vault.appendingPathComponent("stolen")) == "mine")
        #expect(try await store.records() == [record])
    }

    @Test("copy path: a partial swapped before the rename keeps the vault copy and removes nothing it did not create")
    func copyRejectsSwappedPartial() async throws {
        let fix = try QuarantineFixture()
        let file = try fix.makeFile("a.txt", "mine")
        let area = fix.area
        let holder = IDHolder()
        var hooks = QuarantineStore.Hooks(forceCopy: true)
        hooks.beforeRestoreRename = { _ in
            if let id = holder.id {
                let partial = area.appendingPathComponent(".\(id.uuidString).partial")
                swap(partial, aside: area.appendingPathComponent("ours-moved"), with: "mine")
            }
        }
        let store = QuarantineStore(directory: fix.vault, now: { Date() }, hooks: hooks)
        let record = try await store.quarantine(path: file.path, signature: "S")
        holder.id = record.id
        await #expect(throws: QuarantineError.changedSinceScan) { try await store.restore(record.id) }
        // The foreign file the rename placed and our moved copy are both left alone.
        #expect(names(fix.area) == ["a.txt", "ours-moved"])
        #expect(text(fix.vault.appendingPathComponent(record.id.uuidString)) == "mine")
        #expect(try await store.records() == [record])
    }

    @Test("same volume: an unchanged vault copy still restores")
    func moveRestoresUnchanged() async throws {
        let fix = try QuarantineFixture()
        let file = try fix.makeFile("a.txt", "mine")
        let record = try await fix.store.quarantine(path: file.path, signature: "S")
        let restored = try await fix.store.restore(record.id)
        #expect(restored == file.path)
        #expect(text(file) == "mine")
        #expect(!fix.exists(fix.vault.appendingPathComponent(record.id.uuidString)))
        #expect(try await fix.store.records().isEmpty)
    }
}

/// Lets a hook see the record id once the quarantine has produced it.
private final class IDHolder: @unchecked Sendable {
    private let lock = NSLock()
    private var value: UUID?

    var id: UUID? {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }
}
