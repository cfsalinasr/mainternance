import Darwin
import Foundation
@testable import MainternanceData
import MainternanceDomain
import Testing

private let idText = "6F9619FF-8B86-D011-B42D-00C04FC964FF"
private let hashText = String(repeating: "ab", count: 32)

private func recordJSON(path: String) -> String {
    """
    {"id":"\(idText)","originalPath":"\(path)","quarantinedAt":1700000000,"signature":"Eicar-Test-Signature",\
    "sha256":"\(hashText)","size":9000000000,"originalPermissions":493}
    """
}

@Suite("Quarantine manifest recovery and sidecars")
struct QuarantineSidecarTests {
    private func later(_ fix: QuarantineFixture) -> QuarantineStore {
        QuarantineStore(directory: fix.vault, now: { Date() })
    }

    private func corruptNames(_ fix: QuarantineFixture) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: fix.vault.path).filter { $0.hasPrefix("index.corrupt") }
    }

    @Test("a hard-coded sidecar literal decodes with every field and rebuilds a missing manifest")
    func sidecarLiteral() async throws {
        let fix = try QuarantineFixture()
        try FileManager.default.createDirectory(at: fix.vault, withIntermediateDirectories: true)
        try Data(recordJSON(path: "/Users/x/Downloads/eicar.com").utf8)
            .write(to: fix.vault.appendingPathComponent("\(idText).json"))
        try Data("x".utf8).write(to: fix.vault.appendingPathComponent(idText))
        let record = try #require(try await fix.store.records().first)
        #expect(record.id == UUID(uuidString: idText))
        #expect(record.originalPath == "/Users/x/Downloads/eicar.com")
        #expect(record.quarantinedAt == Date(timeIntervalSince1970: 1_700_000_000))
        #expect(record.signature == "Eicar-Test-Signature")
        #expect(record.sha256 == hashText)
        #expect(record.size == 9_000_000_000)
        #expect(record.originalPermissions == 0o755)
    }

    @Test("the sidecar is written with exactly these keys, before and after quarantine, and removed after restore")
    func sidecarKeysAndLifecycle() async throws {
        let fix = try QuarantineFixture()
        let record = try await fix.store.quarantine(path: fix.makeFile("a.txt").path, signature: "S")
        let sidecar = fix.vault.appendingPathComponent("\(record.id.uuidString).json")
        let object = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: sidecar)) as? [String: Any])
        #expect(Set(object.keys) == [
            "id", "originalPath", "quarantinedAt", "signature", "sha256", "size", "originalPermissions"
        ])
        #expect(try QuarantineManifest.decodeRecord(Data(contentsOf: sidecar)) == record)
        _ = try await fix.store.restore(record.id)
        #expect(!fix.exists(sidecar))
    }

    @Test("a corrupt index is rebuilt from the sidecars, the damaged file is kept aside and restore works")
    func corruptIndexRebuilt() async throws {
        let fix = try QuarantineFixture()
        let first = try await fix.store.quarantine(path: fix.makeFile("a.txt", "one").path, signature: "S")
        let second = try await fix.store.quarantine(path: fix.makeFile("b.txt", "two").path, signature: "T")
        try Data("{ not json".utf8).write(to: fix.manifestURL)
        let store = later(fix)
        #expect(try await Set(store.records().map(\.id)) == [first.id, second.id])
        let kept = try corruptNames(fix)
        #expect(kept.count == 1)
        #expect(try String(contentsOf: fix.vault.appendingPathComponent(kept[0]), encoding: .utf8) == "{ not json")
        let restored = try await store.restore(first.id)
        #expect(try String(contentsOfFile: restored, encoding: .utf8) == "one")
        #expect(try await store.records().map(\.id) == [second.id])
        let entries = try QuarantineManifest.decode(Data(contentsOf: fix.manifestURL))
        #expect(entries.map(\.record.id) == [second.id])
    }

    @Test("a deleted index is rebuilt from the sidecars")
    func missingIndexRebuilt() async throws {
        let fix = try QuarantineFixture()
        let record = try await fix.store.quarantine(path: fix.makeFile("a.txt").path, signature: "S")
        try FileManager.default.removeItem(at: fix.manifestURL)
        #expect(try await later(fix).records() == [record])
    }

    @Test("a corrupt index with vault files but no sidecar lists nothing, deletes nothing and reports them")
    func corruptWithoutSidecar() async throws {
        let fix = try QuarantineFixture()
        let record = try await fix.store.quarantine(path: fix.makeFile("a.txt").path, signature: "S")
        try FileManager.default.removeItem(at: fix.vault.appendingPathComponent("\(record.id.uuidString).json"))
        try Data("{ not json".utf8).write(to: fix.manifestURL)
        let store = later(fix)
        #expect(try await store.records().isEmpty)
        #expect(try await store.unclaimedFiles() == [record.id.uuidString])
        #expect(fix.exists(fix.vault.appendingPathComponent(record.id.uuidString)))
        let other = try await store.quarantine(path: fix.makeFile("b.txt").path, signature: "S")
        #expect(try await store.records() == [other])
        #expect(fix.exists(fix.vault.appendingPathComponent(record.id.uuidString)))
        #expect(try corruptNames(fix).count == 1)
    }

    @Test("a vault folder that cannot be listed is an ioFailure")
    func unlistableVault() async throws {
        let fix = try QuarantineFixture()
        _ = try await fix.store.quarantine(path: fix.makeFile("a.txt").path, signature: "S")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: fix.vault.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fix.vault.path) }
        // chmod 000 does not stop root from listing; the owner's own account is not root.
        try #require(getuid() != 0)
        await #expect(throws: QuarantineError.self) { try await later(fix).unclaimedFiles() }
    }

    @Test("a vault folder that does not exist has nothing unclaimed")
    func missingVault() async throws {
        let fix = try QuarantineFixture()
        try? FileManager.default.removeItem(at: fix.vault)
        #expect(try await later(fix).unclaimedFiles().isEmpty)
    }

    @Test("an unreadable index is never replaced: operations fail with ioFailure and write nothing")
    func unreadableIndex() async throws {
        let fix = try QuarantineFixture()
        let record = try await fix.store.quarantine(path: fix.makeFile("a.txt").path, signature: "S")
        let before = try Data(contentsOf: fix.manifestURL)
        let namesBefore = try FileManager.default.contentsOfDirectory(atPath: fix.vault.path).sorted()
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: fix.manifestURL.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fix.manifestURL.path) }
        let store = later(fix)
        let other = try fix.makeFile("b.txt", "keep")
        // The list is reported as unreadable, never as an empty quarantine.
        await #expect(throws: QuarantineError.self) { try await store.records() }
        await #expect(throws: QuarantineError.self) { try await store.stillInPlace() }
        await #expect(throws: QuarantineError.self) { try await store.unclaimedFiles() }
        await #expect(throws: QuarantineError.self) { try await store.quarantine(path: other.path, signature: "S") }
        await #expect(throws: QuarantineError.self) { try await store.restore(record.id) }
        do { _ = try await store.quarantine(path: other.path, signature: "S") } catch {
            guard case .ioFailure = try #require(error as? QuarantineError) else {
                Issue.record("expected ioFailure, got \(error)")
                return
            }
        }
        #expect(try String(contentsOf: other, encoding: .utf8) == "keep")
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fix.manifestURL.path)
        #expect(try Data(contentsOf: fix.manifestURL) == before)
        #expect(try FileManager.default.contentsOfDirectory(atPath: fix.vault.path).sorted() == namesBefore)
    }

    @Test("a failing write is reported as ioFailure, not a raw Cocoa error, and the file stays")
    func writeFailureMapped() async throws {
        let fix = try QuarantineFixture()
        try FileManager.default.createDirectory(at: fix.vault, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: fix.vault.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fix.vault.path) }
        let file = try fix.makeFile("a.txt", "keep")
        do {
            _ = try await fix.store.quarantine(path: file.path, signature: "S")
            Issue.record("expected a failure")
        } catch {
            guard case .ioFailure = try #require(error as? QuarantineError) else {
                Issue.record("expected ioFailure, got \(error)")
                return
            }
        }
        #expect(try String(contentsOf: file, encoding: .utf8) == "keep")
    }

    @Test("an interrupted cross-volume copy (original still in place) is flagged, not reported as contained")
    func stillInPlace() async throws {
        let fix = try QuarantineFixture()
        let file = try fix.makeFile("a.txt", "abc")
        let json = recordJSON(path: file.path).replacingOccurrences(
            of: hashText, with: "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        )
        try FileManager.default.createDirectory(at: fix.vault, withIntermediateDirectories: true)
        try Data(json.utf8).write(to: fix.vault.appendingPathComponent("\(idText).json"))
        try Data("abc".utf8).write(to: fix.vault.appendingPathComponent(idText))
        #expect(try await fix.store.records().isEmpty)
        #expect(try await fix.store.stillInPlace().map(\.originalPath) == [file.path])
        #expect(try String(contentsOf: file, encoding: .utf8) == "abc")
        #expect(fix.exists(fix.vault.appendingPathComponent(idText)))
        await #expect(throws: QuarantineError.missing) {
            try await fix.store.restore(#require(UUID(uuidString: idText)))
        }
    }

    @Test("restore refuses a recorded path that is protected, before moving anything")
    func restoreProtected() async throws {
        let fix = try QuarantineFixture()
        try FileManager.default.createDirectory(at: fix.vault, withIntermediateDirectories: true)
        try Data(recordJSON(path: "/usr/bin/mainternance-test-not-real").utf8)
            .write(to: fix.vault.appendingPathComponent("\(idText).json"))
        try Data("x".utf8).write(to: fix.vault.appendingPathComponent(idText))
        let id = try #require(UUID(uuidString: idText))
        #expect(try await fix.store.records().map(\.id) == [id])
        await #expect(throws: QuarantineError.protectedPath) { try await fix.store.restore(id) }
        #expect(fix.exists(fix.vault.appendingPathComponent(idText)))
        #expect(!FileManager.default.fileExists(atPath: "/usr/bin/mainternance-test-not-real"))
    }

    @Test("a failed permission reset does not fail the restore; the file is back")
    func permissionResetFailure() async throws {
        let fix = try QuarantineFixture(hooks: .init(failRestorePermissions: true))
        let file = try fix.makeFile("a.txt", "hello", mode: 0o755)
        let record = try await fix.store.quarantine(path: file.path, signature: "S")
        #expect(try await fix.store.restore(record.id) == file.path)
        #expect(try String(contentsOf: file, encoding: .utf8) == "hello")
        #expect(permissions(file) == 0o600)
    }
}

@Suite("Quarantine race hardening")
struct QuarantineRaceTests {
    private static func swapForSymlink(at path: String, to decoy: String) {
        try? FileManager.default.removeItem(atPath: path)
        try? FileManager.default.createSymbolicLink(atPath: path, withDestinationPath: decoy)
    }

    @Test(
        "a symlink swapped in after the checks is refused and the real content is never lost",
        arguments: [false, true]
    )
    func symlinkSwap(forceCopy: Bool) async throws {
        let temp = try TempDirectory()
        let area = temp.url.appendingPathComponent("files", isDirectory: true)
        try FileManager.default.createDirectory(at: area, withIntermediateDirectories: true)
        let victim = area.appendingPathComponent("a.txt").path
        let decoy = area.appendingPathComponent("decoy.txt")
        try Data("decoy".utf8).write(to: decoy)
        try Data("real".utf8).write(to: URL(fileURLWithPath: victim))
        var hooks = QuarantineStore.Hooks(forceCopy: forceCopy)
        hooks.beforeMove = { Self.swapForSymlink(at: victim, to: decoy.path) }
        let vault = temp.url.appendingPathComponent("Quarantine", isDirectory: true)
        let store = QuarantineStore(directory: vault, now: { Date() }, hooks: hooks)
        await #expect(throws: QuarantineError.changedSinceScan) { try await store.quarantine(
            path: victim,
            signature: "S"
        ) }
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: victim) == decoy.path)
        #expect(try String(contentsOf: decoy, encoding: .utf8) == "decoy")
        let records = try await store.records()
        if forceCopy {
            // The real file was removed by the swap: the verified vault copy is now its only copy, so it is kept
            // and counts as stored.
            #expect(records.map(\.originalPath) == [victim])
            let copy = try vault.appendingPathComponent(#require(records.first).id.uuidString)
            #expect(try String(contentsOf: copy, encoding: .utf8) == "real")
        } else {
            #expect(records.isEmpty)
            let left = try FileManager.default.contentsOfDirectory(atPath: vault.path)
            #expect(left.filter { $0 != "index.json" }.isEmpty)
        }
    }

    @Test("a parent folder swapped for a symlink after the open is detected and nothing moves")
    func parentSwap() async throws {
        let temp = try TempDirectory()
        let area = temp.url.appendingPathComponent("files", isDirectory: true)
        let moved = temp.url.appendingPathComponent("files-moved", isDirectory: true)
        let other = temp.url.appendingPathComponent("other", isDirectory: true)
        try FileManager.default.createDirectory(at: area, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        try Data("real".utf8).write(to: area.appendingPathComponent("a.txt"))
        try Data("other".utf8).write(to: other.appendingPathComponent("a.txt"))
        var hooks = QuarantineStore.Hooks()
        hooks.beforeMove = {
            try? FileManager.default.moveItem(at: area, to: moved)
            try? FileManager.default.createSymbolicLink(atPath: area.path, withDestinationPath: other.path)
        }
        let vault = temp.url.appendingPathComponent("Quarantine", isDirectory: true)
        let store = QuarantineStore(directory: vault, now: { Date() }, hooks: hooks)
        await #expect(throws: QuarantineError.changedSinceScan) {
            try await store.quarantine(path: area.appendingPathComponent("a.txt").path, signature: "S")
        }
        #expect(try String(contentsOf: other.appendingPathComponent("a.txt"), encoding: .utf8) == "other")
        #expect(try String(contentsOf: moved.appendingPathComponent("a.txt"), encoding: .utf8) == "real")
    }

    @Test("a file reached through a symlinked parent in a normal folder is quarantined and restored in place")
    func symlinkedParentOK() async throws {
        let fix = try QuarantineFixture()
        let file = try fix.makeFile("a.txt", "hi")
        let alias = fix.temp.url.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(atPath: alias.path, withDestinationPath: fix.area.path)
        let viaAlias = alias.appendingPathComponent("a.txt").path
        let record = try await fix.store.quarantine(path: viaAlias, signature: "S")
        #expect(!fix.exists(file))
        #expect(try await fix.store.restore(record.id) == viaAlias)
        #expect(try String(contentsOf: file, encoding: .utf8) == "hi")
    }

    @Test("restore never overwrites even when a symlink sits at the original path")
    func restoreOverSymlink() async throws {
        let fix = try QuarantineFixture()
        let file = try fix.makeFile("a.txt", "mine")
        let record = try await fix.store.quarantine(path: file.path, signature: "S")
        let decoy = try fix.makeFile("decoy.txt", "decoy")
        try FileManager.default.createSymbolicLink(atPath: file.path, withDestinationPath: decoy.path)
        let restored = try await fix.store.restore(record.id)
        #expect(restored == fix.area.appendingPathComponent("a (restored).txt").path)
        #expect(try String(contentsOf: decoy, encoding: .utf8) == "decoy")
        #expect(try String(contentsOfFile: restored, encoding: .utf8) == "mine")
    }
}
