import Foundation
@testable import MainternanceData
import MainternanceDomain
import Testing

/// Everything happens in temp directories created by the test and removed with `defer`/deinit.
struct QuarantineFixture {
    let temp: TempDirectory
    let area: URL
    let vault: URL
    let store: QuarantineStore

    init(now: @escaping @Sendable () -> Date = { Date(timeIntervalSince1970: 1_700_000_000) }) throws {
        temp = try TempDirectory()
        area = temp.url.appendingPathComponent("files", isDirectory: true)
        vault = temp.url.appendingPathComponent("Quarantine", isDirectory: true)
        try FileManager.default.createDirectory(at: area, withIntermediateDirectories: true)
        store = QuarantineStore(directory: vault, now: now)
    }

    @discardableResult
    func makeFile(_ name: String, _ content: String = "payload", mode: Int = 0o644) throws -> URL {
        let url = area.appendingPathComponent(name)
        try Data(content.utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
        return url
    }

    func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    var manifestURL: URL {
        vault.appendingPathComponent("index.json")
    }
}

@Suite("Quarantine store")
struct QuarantineStoreTests {
    @Test("quarantine then restore round-trips content, permissions and the path")
    func roundTrip() async throws {
        let fix = try QuarantineFixture()
        let file = try fix.makeFile("a.txt", "hello", mode: 0o755)
        let record = try await fix.store.quarantine(path: file.path, signature: "Eicar")
        #expect(!fix.exists(file))
        #expect(record.originalPath == file.path)
        #expect(record.signature == "Eicar")
        #expect(record.originalPermissions == 0o755)
        let restored = try await fix.store.restore(record.id)
        #expect(restored == file.path)
        #expect(try String(contentsOf: file, encoding: .utf8) == "hello")
        #expect(permissions(file) == 0o755)
        #expect(await fix.store.records().isEmpty)
    }

    @Test("hash and size are recorded, the copy has no execute bit and the manifest lists it")
    func hashAndMode() async throws {
        let fix = try QuarantineFixture()
        let file = try fix.makeFile("a.txt", "abc", mode: 0o755)
        let record = try await fix.store.quarantine(path: file.path, signature: "S")
        #expect(record.sha256 == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        #expect(record.size == 3)
        #expect(record.quarantinedAt == Date(timeIntervalSince1970: 1_700_000_000))
        let stored = fix.vault.appendingPathComponent(record.id.uuidString)
        #expect(fix.exists(stored))
        #expect(permissions(stored) == 0o600)
        #expect(await fix.store.records() == [record])
    }

    @Test("a streamed hash over several chunks matches the one-shot hash")
    func bigFile() async throws {
        let fix = try QuarantineFixture()
        let file = try fix.makeFile("big.bin", String(repeating: "0123456789", count: 300_000))
        let record = try await fix.store.quarantine(path: file.path, signature: "S")
        #expect(record.size == 3_000_000)
        #expect(record.sha256 == QuarantineStore
            .sha256Hex(of: Data(String(repeating: "0123456789", count: 300_000).utf8)))
    }

    @Test("protected paths are refused and left alone")
    func protectedRefused() async throws {
        let fix = try QuarantineFixture()
        for path in ["/usr/bin/true", "/etc/hosts", "/", fix.vault.path] {
            await #expect(throws: QuarantineError.protectedPath) {
                try await fix.store.quarantine(path: path, signature: "S")
            }
        }
        #expect(FileManager.default.fileExists(atPath: "/usr/bin/true"))
    }

    @Test("a file already inside the quarantine folder is refused")
    func insideVault() async throws {
        let fix = try QuarantineFixture()
        let file = try fix.makeFile("a.txt")
        let record = try await fix.store.quarantine(path: file.path, signature: "S")
        await #expect(throws: QuarantineError.protectedPath) {
            try await fix.store.quarantine(
                path: fix.vault.appendingPathComponent(record.id.uuidString).path,
                signature: "S"
            )
        }
    }

    @Test("symlinks and directories are rejected, missing files are missing")
    func rejections() async throws {
        let fix = try QuarantineFixture()
        let target = try fix.makeFile("t.txt")
        let link = fix.area.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: target.path)
        let dangling = fix.area.appendingPathComponent("dangling")
        try FileManager.default.createSymbolicLink(atPath: dangling.path, withDestinationPath: "/nonexistent-x")
        let folder = fix.area.appendingPathComponent("dir", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for path in [link.path, dangling.path, folder.path] {
            await #expect(throws: QuarantineError.notRegularFile) {
                try await fix.store.quarantine(path: path, signature: "S")
            }
        }
        await #expect(throws: QuarantineError.missing) {
            try await fix.store.quarantine(path: fix.area.appendingPathComponent("nope").path, signature: "S")
        }
        #expect(fix.exists(target))
        #expect(await fix.store.records().isEmpty)
    }

    @Test("quarantining the same path twice: the second is .missing because the file is gone")
    func samePathTwice() async throws {
        let fix = try QuarantineFixture()
        let file = try fix.makeFile("a.txt")
        _ = try await fix.store.quarantine(path: file.path, signature: "S")
        await #expect(throws: QuarantineError.missing) {
            try await fix.store.quarantine(path: file.path, signature: "S")
        }
        #expect(await fix.store.records().count == 1)
    }

    @Test("restore never overwrites: a collision restores next to it with a suffix")
    func collision() async throws {
        let fix = try QuarantineFixture()
        let file = try fix.makeFile("a.txt", "old")
        let record = try await fix.store.quarantine(path: file.path, signature: "S")
        try fix.makeFile("a.txt", "new")
        let restored = try await fix.store.restore(record.id)
        #expect(restored == fix.area.appendingPathComponent("a (restored).txt").path)
        #expect(try String(contentsOf: file, encoding: .utf8) == "new")
        #expect(try String(contentsOfFile: restored, encoding: .utf8) == "old")
    }

    @Test("a second collision gets a numbered suffix and a dangling symlink counts as taken")
    func collisionTwice() async throws {
        let fix = try QuarantineFixture()
        let file = try fix.makeFile("a.txt", "one")
        let record = try await fix.store.quarantine(path: file.path, signature: "S")
        try fix.makeFile("a.txt", "new")
        try fix.makeFile("a (restored).txt", "taken")
        let dangling = fix.area.appendingPathComponent("a (restored 2).txt")
        try FileManager.default.createSymbolicLink(atPath: dangling.path, withDestinationPath: "/nonexistent-x")
        let restored = try await fix.store.restore(record.id)
        #expect(restored == fix.area.appendingPathComponent("a (restored 3).txt").path)
        #expect(try String(contentsOf: fix.area.appendingPathComponent("a (restored).txt"), encoding: .utf8) == "taken")
    }

    @Test("restore with a missing original folder moves nothing")
    func missingFolder() async throws {
        let fix = try QuarantineFixture()
        let sub = fix.area.appendingPathComponent("sub", isDirectory: true)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        let file = sub.appendingPathComponent("a.txt")
        try Data("x".utf8).write(to: file)
        let record = try await fix.store.quarantine(path: file.path, signature: "S")
        try FileManager.default.removeItem(at: sub)
        await #expect(throws: QuarantineError.restoreTargetMissing) { try await fix.store.restore(record.id) }
        #expect(fix.exists(fix.vault.appendingPathComponent(record.id.uuidString)))
        #expect(await fix.store.records() == [record])
        #expect(!fix.exists(sub))
    }

    @Test("unknown ids and already restored ids are .missing")
    func unknownAndTwice() async throws {
        let fix = try QuarantineFixture()
        await #expect(throws: QuarantineError.missing) { try await fix.store.restore(UUID()) }
        let file = try fix.makeFile("a.txt")
        let record = try await fix.store.quarantine(path: file.path, signature: "S")
        _ = try await fix.store.restore(record.id)
        await #expect(throws: QuarantineError.missing) { try await fix.store.restore(record.id) }
    }

    @Test("the manifest and records survive a new store instance")
    func persistence() async throws {
        let fix = try QuarantineFixture()
        let record = try await fix.store.quarantine(path: fix.makeFile("a.txt").path, signature: "S")
        let again = QuarantineStore(directory: fix.vault, now: { Date() })
        #expect(await again.records() == [record])
        _ = try await again.restore(record.id)
    }

    @Test("a corrupt manifest is survived: empty list, files kept, later quarantines keep the old manifest aside")
    func corruptManifest() async throws {
        let fix = try QuarantineFixture()
        let first = try await fix.store.quarantine(path: fix.makeFile("a.txt").path, signature: "S")
        try Data("{ not json".utf8).write(to: fix.manifestURL)
        let store = QuarantineStore(directory: fix.vault, now: { Date() })
        #expect(await store.records().isEmpty)
        #expect(fix.exists(fix.vault.appendingPathComponent(first.id.uuidString)))
        let second = try await store.quarantine(path: fix.makeFile("b.txt").path, signature: "S")
        #expect(await store.records() == [second])
        let kept = try FileManager.default.contentsOfDirectory(atPath: fix.vault.path)
            .filter { $0.hasPrefix("index.corrupt") }
        #expect(kept.count == 1)
        #expect(try String(contentsOf: fix.vault.appendingPathComponent(kept[0]), encoding: .utf8) == "{ not json")
        #expect(fix.exists(fix.vault.appendingPathComponent(first.id.uuidString)))
    }

    @Test("a missing manifest yields an empty list and creates nothing")
    func missingManifest() async throws {
        let fix = try QuarantineFixture()
        #expect(await fix.store.records().isEmpty)
        #expect(!fix.exists(fix.vault))
    }

    @Test("concurrent quarantines of different files all succeed and all are in the manifest")
    func concurrent() async throws {
        let fix = try QuarantineFixture()
        let paths = try (0 ..< 12).map { try fix.makeFile("f\($0).txt", "content \($0)").path }
        let store = fix.store
        try await withThrowingTaskGroup(of: UUID.self) { group in
            for path in paths {
                group.addTask { try await store.quarantine(path: path, signature: "S").id }
            }
            var ids = Set<UUID>()
            for try await id in group {
                ids.insert(id)
            }
            #expect(ids.count == 12)
        }
        let listed = await store.records()
        #expect(listed.count == 12)
        #expect(Set(listed.map(\.originalPath)) == Set(paths))
        let onDisk = QuarantineStore(directory: fix.vault, now: { Date() })
        #expect(await onDisk.records().count == 12)
    }
}

@Suite("Quarantine store, cross-volume copy path")
struct QuarantineCrossVolumeTests {
    private func forcedCopyStore(_ fix: QuarantineFixture) -> QuarantineStore {
        QuarantineStore(directory: fix.vault, now: { Date() }, isSameVolume: { _, _ in false })
    }

    @Test("copy, verify, then remove the original; restore goes back the same way; no partial files remain")
    func copyRoundTrip() async throws {
        let fix = try QuarantineFixture()
        let store = forcedCopyStore(fix)
        let file = try fix.makeFile("a.txt", "abc", mode: 0o755)
        let record = try await store.quarantine(path: file.path, signature: "S")
        #expect(!fix.exists(file))
        #expect(record.sha256 == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        let stored = fix.vault.appendingPathComponent(record.id.uuidString)
        #expect(permissions(stored) == 0o600)
        let restored = try await store.restore(record.id)
        #expect(restored == file.path)
        #expect(try String(contentsOf: file, encoding: .utf8) == "abc")
        #expect(permissions(file) == 0o755)
        #expect(fix.temp.names == ["Quarantine", "files"])
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: fix.area.path)
        #expect(leftovers == ["a.txt"])
        #expect(try !(FileManager.default.contentsOfDirectory(atPath: fix.vault.path))
            .contains { $0.hasSuffix(".partial") })
    }

    @Test("when the original cannot be removed the file is not lost and nothing is half-recorded")
    func originalNotRemovable() async throws {
        let fix = try QuarantineFixture()
        let store = forcedCopyStore(fix)
        let file = try fix.makeFile("a.txt", "keep")
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: fix.area.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fix.area.path) }
        await #expect(throws: QuarantineError.self) { try await store.quarantine(path: file.path, signature: "S") }
        #expect(try String(contentsOf: file, encoding: .utf8) == "keep")
        #expect(await store.records().isEmpty)
        let vaultFiles = try FileManager.default.contentsOfDirectory(atPath: fix.vault.path)
        #expect(vaultFiles.filter { $0 != "index.json" }.isEmpty)
    }
}
