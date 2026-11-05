import Foundation
@testable import MainternanceData
import MainternanceDomain
import Testing

private func names(_ url: URL) -> [String] {
    ((try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []).sorted()
}

/// Overwrites the start of the file in place (same inode, same size).
private func overwrite(_ url: URL, with text: String) {
    guard let handle = try? FileHandle(forWritingTo: url) else { return }
    try? handle.write(contentsOf: Data(text.utf8))
    try? handle.close()
}

@Suite("Quarantine restore, half-written copies and verification")
struct QuarantineRestorePartialTests {
    @Test("a vault copy altered with the same size fails the restore, keeps the vault copy and leaves no partial")
    func alteredVaultCopy() async throws {
        let fix = try QuarantineFixture()
        let file = try fix.makeFile("a.txt", "mine")
        let vault = fix.vault
        let holder = IDHolder()
        var hooks = QuarantineStore.Hooks(forceCopy: true)
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
        let copy = fix.vault.appendingPathComponent(record.id.uuidString)
        #expect(try String(contentsOf: copy, encoding: .utf8) == "evil")
        #expect(try await store.records() == [record])
    }

    @Test("a partial left by an earlier crashed copy restore is cleared and the restore succeeds")
    func leftoverPartialCopyPath() async throws {
        let fix = try QuarantineFixture()
        let file = try fix.makeFile("a.txt", "mine")
        let store = QuarantineStore(directory: fix.vault, now: { Date() }, hooks: .init(forceCopy: true))
        let record = try await store.quarantine(path: file.path, signature: "S")
        let partial = fix.area.appendingPathComponent(".\(record.id.uuidString).partial")
        try Data("half".utf8).write(to: partial)
        let restored = try await store.restore(record.id)
        #expect(restored == file.path)
        #expect(try String(contentsOf: file, encoding: .utf8) == "mine")
        #expect(names(fix.area) == ["a.txt"])
        #expect(try await store.records().isEmpty)
    }

    @Test("a failed move that created no partial does not delete a partial already in the folder")
    func failedMoveKeepsForeignPartial() async throws {
        let fix = try QuarantineFixture()
        let file = try fix.makeFile("a.txt", "mine")
        let vault = fix.vault
        var hooks = QuarantineStore.Hooks()
        // The vault becomes read-only after the destination opened: the move out of it fails with a plain I/O error.
        hooks.afterRestoreFolderOpen = {
            try? FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: vault.path)
        }
        let store = QuarantineStore(directory: fix.vault, now: { Date() }, hooks: hooks)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: vault.path) }
        let record = try await store.quarantine(path: file.path, signature: "S")
        let partial = fix.area.appendingPathComponent(".\(record.id.uuidString).partial")
        try Data("not ours".utf8).write(to: partial)
        await #expect(throws: QuarantineError.self) { try await store.restore(record.id) }
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: vault.path)
        #expect(try String(contentsOf: partial, encoding: .utf8) == "not ours")
        #expect(try await store.records() == [record])
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
