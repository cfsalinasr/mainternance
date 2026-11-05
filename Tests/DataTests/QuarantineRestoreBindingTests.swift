import Darwin
import Foundation
@testable import MainternanceData
import MainternanceDomain
import Testing

private func physical(_ url: URL) -> String {
    guard let real = realpath(url.path, nil) else { return url.path }
    defer { free(real) }
    return String(cString: real)
}

private func names(_ url: URL) -> [String] {
    ((try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []).sorted()
}

/// Moves `folder` to `aside` and puts a symlink to `decoy` where it was.
private func swapForSymlink(_ folder: URL, aside: URL, decoy: URL) {
    try? FileManager.default.moveItem(at: folder, to: aside)
    try? FileManager.default.createSymbolicLink(atPath: folder.path, withDestinationPath: decoy.path)
}

@Suite("Quarantine restore is bound to the checked destination folder")
struct QuarantineRestoreBindingTests {
    @Test("a destination folder swapped for a symlink after it was opened still receives the file", arguments: [
        false, true
    ])
    func swapAfterOpen(forceCopy: Bool) async throws {
        let fix = try QuarantineFixture()
        let file = try fix.makeFile("a.txt", "mine", mode: 0o640)
        let moved = fix.temp.url.appendingPathComponent("files-moved", isDirectory: true)
        let other = fix.temp.url.appendingPathComponent("other", isDirectory: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        let area = fix.area
        var hooks = QuarantineStore.Hooks(forceCopy: forceCopy)
        hooks.afterRestoreFolderOpen = { swapForSymlink(area, aside: moved, decoy: other) }
        let store = QuarantineStore(directory: fix.vault, now: { Date() }, hooks: hooks)
        let record = try await store.quarantine(path: file.path, signature: "S")
        let restored = try await store.restore(record.id)
        let landed = moved.appendingPathComponent("a.txt")
        #expect(restored == physical(moved) + "/a.txt")
        #expect(try String(contentsOf: landed, encoding: .utf8) == "mine")
        #expect(permissions(landed) == 0o640)
        #expect(names(other).isEmpty)
        #expect(names(moved) == ["a.txt"])
        #expect(try await store.records().isEmpty)
    }

    @Test("a destination folder swapped for a symlink between the check and the open is refused")
    func swapBeforeOpen() async throws {
        let fix = try QuarantineFixture()
        let file = try fix.makeFile("a.txt", "mine")
        let moved = fix.temp.url.appendingPathComponent("files-moved", isDirectory: true)
        let other = fix.temp.url.appendingPathComponent("other", isDirectory: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        let area = fix.area
        var hooks = QuarantineStore.Hooks()
        hooks.beforeRestoreFolderOpen = { swapForSymlink(area, aside: moved, decoy: other) }
        let store = QuarantineStore(directory: fix.vault, now: { Date() }, hooks: hooks)
        let record = try await store.quarantine(path: file.path, signature: "S")
        await #expect(throws: QuarantineError.changedSinceScan) { try await store.restore(record.id) }
        #expect(names(other).isEmpty)
        #expect(names(moved).isEmpty)
        #expect(fix.exists(fix.vault.appendingPathComponent(record.id.uuidString)))
        #expect(try await store.records() == [record])
    }

    @Test("a folder higher up swapped so the opened folder lies in the quarantine folder is refused")
    func intermediateSwapIntoVault() async throws {
        let fix = try QuarantineFixture()
        let outer = fix.temp.url.appendingPathComponent("outer", isDirectory: true)
        let area = outer.appendingPathComponent("files", isDirectory: true)
        try FileManager.default.createDirectory(at: area, withIntermediateDirectories: true)
        let file = area.appendingPathComponent("a.txt")
        try Data("mine".utf8).write(to: file)
        let vault = fix.vault
        let trap = vault.appendingPathComponent("files", isDirectory: true)
        let outerAside = fix.temp.url.appendingPathComponent("outer-moved")
        var hooks = QuarantineStore.Hooks()
        hooks.beforeRestoreFolderOpen = {
            try? FileManager.default.createDirectory(at: trap, withIntermediateDirectories: true)
            swapForSymlink(outer, aside: outerAside, decoy: vault)
        }
        let store = QuarantineStore(directory: vault, now: { Date() }, hooks: hooks)
        let record = try await store.quarantine(path: file.path, signature: "S")
        await #expect(throws: QuarantineError.protectedPath) { try await store.restore(record.id) }
        #expect(names(trap).isEmpty)
        #expect(fix.exists(vault.appendingPathComponent(record.id.uuidString)))
        #expect(try await store.records() == [record])
    }

    @Test("a destination folder that became a symlink into the quarantine folder is refused")
    func parentSymlinkIntoVault() async throws {
        let fix = try QuarantineFixture()
        let file = try fix.makeFile("a.txt", "mine")
        let record = try await fix.store.quarantine(path: file.path, signature: "S")
        swapForSymlink(fix.area, aside: fix.temp.url.appendingPathComponent("files-moved"), decoy: fix.vault)
        await #expect(throws: QuarantineError.protectedPath) { try await fix.store.restore(record.id) }
        #expect(!names(fix.vault).contains("a.txt"))
        #expect(try await fix.store.records() == [record])
    }

    @Test("a destination folder that became a symlink to a file is a missing target")
    func parentSymlinkToFile() async throws {
        let fix = try QuarantineFixture()
        let file = try fix.makeFile("a.txt", "mine")
        let record = try await fix.store.quarantine(path: file.path, signature: "S")
        let plain = fix.temp.url.appendingPathComponent("plain.txt")
        try Data("plain".utf8).write(to: plain)
        swapForSymlink(fix.area, aside: fix.temp.url.appendingPathComponent("files-moved"), decoy: plain)
        await #expect(throws: QuarantineError.restoreTargetMissing) { try await fix.store.restore(record.id) }
        #expect(try String(contentsOf: plain, encoding: .utf8) == "plain")
        #expect(try await fix.store.records() == [record])
    }
}

@Suite("Quarantine keeps its copy when the original cannot be removed")
struct QuarantineKeepsCopyTests {
    @Test("the original is still there with the same content: the copy is kept and flagged as still in place")
    func originalStillThere() async throws {
        let fix = try QuarantineFixture()
        let store = QuarantineStore(directory: fix.vault, now: { Date() }, hooks: .init(forceCopy: true))
        let file = try fix.makeFile("a.txt", "keep")
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: fix.area.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fix.area.path) }
        await #expect(throws: QuarantineError.self) { try await store.quarantine(path: file.path, signature: "S") }
        #expect(try String(contentsOf: file, encoding: .utf8) == "keep")
        #expect(try await store.records().isEmpty)
        let flagged = try await store.stillInPlace()
        #expect(flagged.map(\.originalPath) == [file.path])
        let copy = try fix.vault.appendingPathComponent(#require(flagged.first).id.uuidString)
        #expect(try String(contentsOf: copy, encoding: .utf8) == "keep")
    }

    @Test("the original was replaced before its removal: the copy is the only old content, kept and stored")
    func originalReplaced() async throws {
        let fix = try QuarantineFixture()
        let file = try fix.makeFile("a.txt", "old")
        var hooks = QuarantineStore.Hooks(forceCopy: true)
        hooks.beforeOriginalRemoval = {
            try? FileManager.default.removeItem(at: file)
            try? Data("new".utf8).write(to: file)
        }
        let store = QuarantineStore(directory: fix.vault, now: { Date() }, hooks: hooks)
        await #expect(throws: QuarantineError.changedSinceScan) {
            try await store.quarantine(path: file.path, signature: "S")
        }
        #expect(try String(contentsOf: file, encoding: .utf8) == "new")
        let records = try await store.records()
        #expect(records.map(\.originalPath) == [file.path])
        let copy = try fix.vault.appendingPathComponent(#require(records.first).id.uuidString)
        #expect(try String(contentsOf: copy, encoding: .utf8) == "old")
        #expect(try await store.stillInPlace().isEmpty)
    }
}
