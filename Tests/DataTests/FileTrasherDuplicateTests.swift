import Foundation
@testable import MainternanceData
import MainternanceDomain
import Testing

/// Moving duplicate copies to a fake Trash inside a temp folder: at least one copy must always stay, unchanged.
@Suite("File trasher: duplicates")
struct FileTrasherDuplicateTests {
    @Test("the chosen copies move and the kept copy stays")
    func keepsOne() async throws {
        let fixture = try FilesFixture()
        let group = try fixture.group(["a/copy.bin", "b/copy.bin", "c/copy.bin"])
        let trash = fixture.trash()
        let remove = Array(group.files.dropFirst())
        let outcome = await fixture.trasher(trash).moveDuplicatesToTrash(group, remove: remove)
        #expect(outcome.moved == remove)
        #expect(outcome.failed.isEmpty)
        #expect(outcome.movedBytes == remove.reduce(0) { $0 + $1.bytes })
        #expect(trash.moves.map(\.source.path) == remove.map(\.id))
        #expect(fixture.exists(URL(fileURLWithPath: group.files[0].id)))
    }

    @Test("removing every copy is refused and nothing is offered to the Trash")
    func refusesAllCopies() async throws {
        let fixture = try FilesFixture()
        let group = try fixture.group(["a/copy.bin", "b/copy.bin"])
        let trash = fixture.trash()
        let outcome = await fixture.trasher(trash).moveDuplicatesToTrash(group, remove: group.files.reversed())
        #expect(outcome.moved.isEmpty && outcome.movedBytes == 0)
        #expect(outcome.failed.map(\.reason) == [FileRefusal.wouldLeaveNoCopy.text, FileRefusal.wouldLeaveNoCopy.text])
        #expect(trash.calls.isEmpty)
        #expect(group.files.allSatisfy { fixture.exists(URL(fileURLWithPath: $0.id)) })
    }

    @Test("naming the same copy twice still cannot remove the last one")
    func repeatedCopy() async throws {
        let fixture = try FilesFixture()
        let group = try fixture.group(["a/copy.bin", "b/copy.bin"])
        let trash = fixture.trash()
        let remove = [group.files[0], group.files[1], group.files[1]]
        let outcome = await fixture.trasher(trash).moveDuplicatesToTrash(group, remove: remove)
        #expect(outcome.moved.isEmpty)
        #expect(trash.calls.isEmpty)
    }

    @Test("a file to remove that is not a copy in the group is refused, and nothing moves")
    func notInGroup() async throws {
        let fixture = try FilesFixture()
        let group = try fixture.group(["a/copy.bin", "b/copy.bin", "c/copy.bin"])
        let stranger = try fixture.item(fixture.file("other.bin"))
        let forged = group.files[2].with(bytes: group.files[2].bytes + 4096)
        let trash = fixture.trash()
        let trasher = fixture.trasher(trash)
        for remove in [[group.files[1], stranger], [group.files[1], forged]] {
            let outcome = await trasher.moveDuplicatesToTrash(group, remove: remove)
            #expect(outcome.moved.isEmpty)
            #expect(outcome.failed.map(\.reason) == [FileRefusal.notInGroup.text, FileRefusal.notInGroup.text])
        }
        #expect(trash.calls.isEmpty)
    }

    @Test("no kept copy still there unchanged (gone, replaced, resized, re-dated): refused, nothing moves")
    func keptCopyMustStillExist() async throws {
        let changes: [(FilesFixture, URL) throws -> Void] = [
            { _, url in try FileManager.default.removeItem(at: url) },
            { fixture, url in try fixture.replace(url) },
            { fixture, url in try fixture.grow(url) },
            { fixture, url in try fixture.setModified(url, 3_000_000) }
        ]
        for change in changes {
            let fixture = try FilesFixture()
            let group = try fixture.group(["a/copy.bin", "b/copy.bin"])
            try change(fixture, URL(fileURLWithPath: group.files[0].id))
            let trash = fixture.trash()
            let outcome = await fixture.trasher(trash).moveDuplicatesToTrash(group, remove: [group.files[1]])
            #expect(outcome.failed.map(\.reason) == [FileRefusal.noKeptCopy.text])
            #expect(trash.calls.isEmpty)
            #expect(fixture.exists(URL(fileURLWithPath: group.files[1].id)))
        }
    }

    @Test("one good kept copy is enough when another kept copy has gone")
    func oneGoodKeptCopyIsEnough() async throws {
        let fixture = try FilesFixture()
        let group = try fixture.group(["a/copy.bin", "b/copy.bin", "c/copy.bin"])
        try FileManager.default.removeItem(atPath: group.files[0].id)
        let trash = fixture.trash()
        let outcome = await fixture.trasher(trash).moveDuplicatesToTrash(group, remove: [group.files[2]])
        #expect(outcome.moved == [group.files[2]])
        #expect(fixture.exists(URL(fileURLWithPath: group.files[1].id)))
    }

    @Test("a kept copy that is the same item as a removed one (a hard link) does not count as a copy")
    func hardLinkIsNotACopy() async throws {
        let fixture = try FilesFixture()
        let original = try fixture.write("a/copy.bin", pattern(4096))
        let linked = fixture.home.appendingPathComponent("b/copy.bin")
        try FileManager.default.createDirectory(
            at: linked.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try FileManager.default.linkItem(at: original, to: linked)
        let items = try [original, linked].map(fixture.item)
        let group = DuplicateGroup(id: "forged", bytesEach: items[0].bytes, files: items)
        let trash = fixture.trash()
        let outcome = await fixture.trasher(trash).moveDuplicatesToTrash(group, remove: [items[1]])
        #expect(outcome.failed.map(\.reason) == [FileRefusal.noKeptCopy.text])
        #expect(trash.calls.isEmpty)
    }

    @Test("if the kept copy disappears part way, the remaining moves are refused")
    func keptCopyGoesMidway() async throws {
        let fixture = try FilesFixture()
        let group = try fixture.group(["a/copy.bin", "b/copy.bin", "c/copy.bin"])
        let kept = group.files[0].id
        let trash = fixture.trash(refuses: { _ in
            try? FileManager.default.removeItem(atPath: kept)
            return false
        })
        let outcome = await fixture.trasher(trash).moveDuplicatesToTrash(
            group,
            remove: [group.files[1], group.files[2]]
        )
        #expect(outcome.moved == [group.files[1]])
        #expect(outcome.failed == [FileFailure(file: group.files[2], reason: FileRefusal.noKeptCopy.text)])
        #expect(trash.calls.count == 1)
        #expect(fixture.exists(URL(fileURLWithPath: group.files[2].id)))
    }

    @Test("a copy to remove that changed is refused; the other chosen copies still move")
    func changedCopyRefusedOthersMove() async throws {
        let fixture = try FilesFixture()
        let group = try fixture.group(["a/copy.bin", "b/copy.bin", "c/copy.bin"])
        try fixture.grow(URL(fileURLWithPath: group.files[1].id))
        let trash = fixture.trash()
        let outcome = await fixture.trasher(trash).moveDuplicatesToTrash(
            group,
            remove: [group.files[1], group.files[2]]
        )
        #expect(outcome.moved == [group.files[2]])
        #expect(outcome.failed == [FileFailure(file: group.files[1], reason: FileRefusal.changed.text)])
        #expect(outcome.movedBytes == group.files[2].bytes)
    }

    @Test("a copy to remove under ~/Library is refused like any single file")
    func copyUnderLibrary() async throws {
        let fixture = try FilesFixture()
        let group = try fixture.group(["Documents/copy.bin", "Library/copy.bin"])
        let trash = fixture.trash()
        let outcome = await fixture.trasher(trash).moveDuplicatesToTrash(group, remove: [group.files[1]])
        #expect(outcome.failed.map(\.reason) == [FileRefusal.hiddenPlace.text])
        #expect(trash.calls.isEmpty)
    }

    @Test("nothing to remove moves nothing")
    func emptyRemove() async throws {
        let fixture = try FilesFixture()
        let group = try fixture.group(["a/copy.bin", "b/copy.bin"])
        let trash = fixture.trash()
        let outcome = await fixture.trasher(trash).moveDuplicatesToTrash(group, remove: [])
        #expect(outcome == FileTrashOutcome(moved: [], failed: []))
        #expect(trash.calls.isEmpty)
    }
}
