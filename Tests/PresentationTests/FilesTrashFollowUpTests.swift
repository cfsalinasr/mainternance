import Foundation
import MainternanceDomain
@testable import MainternancePresentation
import Testing

@MainActor
struct FilesFixRoundTests {
    private let one = FilesRig.file("/h/a/x.bin", bytes: 2_000_000, age: 100)
    private let two = FilesRig.file("/h/b/x.bin", bytes: 2_000_000, age: 50)
    private let three = FilesRig.file("/h/c/x.bin", bytes: 2_000_000, age: 0)

    private func scanDisk(_ rig: FilesRig, index: Int = 0) async {
        rig.state.startDiskScan()
        await rig.disk.waitForStarts(index + 1)
        rig.disk.send(.finished(FilesRig.result(files: [one])), scan: index)
        await rig.state.waitForScan()
    }

    @Test func aMoveMakesTheMapStaleAndANewScanClearsIt() async {
        let rig = FilesRig()
        await scanDisk(rig)
        #expect(rig.state.staleMapNote == nil)
        rig.state.requestTrash(one)
        await rig.state.confirm()
        #expect(rig.state.diskMapIsStale)
        #expect(rig.state.staleMapNote == "The map was drawn before your last move. Scan again to update it.")
        await scanDisk(rig, index: 1)
        #expect(!rig.state.diskMapIsStale)
    }

    @Test func aMoveThatMovedNothingLeavesTheMapFresh() async {
        let rig = FilesRig()
        rig.trasher.refuse(one.id, reason: "No.")
        await scanDisk(rig)
        rig.state.requestTrash(one)
        await rig.state.confirm()
        #expect(!rig.state.diskMapIsStale)
    }

    @Test func leavingTheScreenClosesAnOpenReview() async {
        let rig = FilesRig()
        rig.state.requestTrash(one)
        #expect(rig.state.isReviewing)
        rig.state.cancelWork()
        #expect(!rig.state.isReviewing)
        await rig.state.confirm()
        #expect(rig.trasher.calls.isEmpty)
    }

    @Test func leavingTheScreenDoesNotInterruptAMoveInProgress() async {
        let gated = GatedTrasher()
        let rig = FilesRig(trasher: gated)
        rig.state.requestTrash(one)
        let move = Task { await rig.state.confirm() }
        await rig.until { rig.state.isMoving }
        rig.state.cancelWork()
        #expect(rig.state.isMoving)
        await gated.gate.waitForCall()
        gated.gate.release(FileTrashOutcome(moved: [one], failed: []))
        await move.value
        #expect(rig.state.lastOutcome?.moved == [one])
    }

    @Test func trashingOneCopyFromSearchShrinksOrRemovesItsGroup() async {
        let rig = FilesRig()
        await rig.scanDuplicates([
            FilesRig.group("three", [one, two, three]),
            FilesRig.group("pair", [FilesRig.file("/h/p1.bin"), FilesRig.file("/h/p2.bin")])
        ])
        rig.state.requestTrash(three)
        await rig.state.confirm()
        #expect(rig.state.duplicateGroups.first { $0.id == "three" }?.files.map(\.id) == [one.id, two.id])
        rig.state.requestTrash(FilesRig.file("/h/p1.bin"))
        await rig.state.confirm()
        #expect(rig.state.duplicateGroups.map(\.id) == ["three"])
    }

    @Test func aStoppedScanShowsAtLeast() async {
        let rig = FilesRig()
        rig.state.startDuplicateScan()
        await rig.duplicates.waitForStarts(1)
        rig.duplicates.send(.group(FilesRig.group("g", [one, two])))
        rig.duplicates.send(.finished(unreadableFolders: 0, wasCancelled: true))
        await rig.state.waitForDuplicateScan()
        #expect(rig.state.duplicatesTotalText.hasPrefix("at least"))
    }
}
