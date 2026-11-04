import Foundation
import MainternanceDomain
@testable import MainternancePresentation
import Testing

@MainActor
struct KeepRuleTests {
    private func file(_ path: String, _ age: TimeInterval) -> FileItem {
        FilesRig.file(path, bytes: 1, age: age)
    }

    @Test func newestKeepsLatest() {
        let group = [file("/a", 100), file("/b", 0), file("/c", 50)]
        let selection = DuplicateSelection(group: group, rule: .newest)
        #expect(selection.kept?.id == "/b")
        #expect(selection.removable.count == 2)
    }

    @Test func oldestKeepsEarliest() {
        let group = [file("/a", 10), file("/b", 0), file("/c", 500)]
        #expect(DuplicateSelection(group: group, rule: .oldest).kept?.id == "/c")
    }

    @Test func shortestPathKeepsShortest() {
        let group = [file("/long/path/x", 0), file("/s", 100), file("/mid/x", 50)]
        #expect(DuplicateSelection(group: group, rule: .shortestPath).kept?.id == "/s")
    }

    @Test func tiesBreakByShorterThenAlphabeticalPathWhateverTheOrder() {
        let same = [file("/bb", 0), file("/aa", 0)]
        for rule in KeepRule.allCases {
            #expect(DuplicateSelection(group: same, rule: rule).kept?.id == "/aa")
            #expect(DuplicateSelection(group: same.reversed(), rule: rule).kept?.id == "/aa")
        }
        let longerOlder = [file("/long/one", 0), file("/s", 0)]
        #expect(DuplicateSelection(group: longerOlder, rule: .oldest).kept?.id == "/s")
    }

    @Test func exactlyOneIsKeptAndNeverAllCopies() {
        let groups = [
            [file("/a", 0), file("/b", 0)],
            [file("/a", 0), file("/b", 5), file("/c", 9)],
            [file("/only", 0)]
        ]
        for group in groups {
            for rule in KeepRule.allCases {
                let selection = DuplicateSelection(group: group, rule: rule)
                #expect(selection.kept != nil)
                #expect(selection.removable.count == group.count - 1)
                #expect(!selection.removable.contains { $0.id == selection.kept?.id })
                #expect(group.filter(selection.isKept).count == 1)
            }
        }
    }

    @Test func emptyGroupKeepsNothingAndRemovesNothing() {
        let selection = DuplicateSelection(group: [], rule: .newest)
        #expect(selection.kept == nil)
        #expect(selection.removable.isEmpty)
    }
}

@MainActor
struct FilesDuplicateScanTests {
    private let one = FilesRig.group("g1", [FilesRig.file("/h/a/x.bin"), FilesRig.file("/h/b/x.bin")])

    @Test func groupsStreamInWithPhaseAndEndTheScan() async {
        let rig = FilesRig()
        rig.state.startDuplicateScan()
        #expect(rig.state.isFindingDuplicates)
        await rig.duplicates.waitForStarts(1)
        rig.duplicates.send(.phase("Comparing 4 files"))
        await rig.until { rig.state.duplicatePhase != nil }
        #expect(rig.state.duplicatePhase == "Comparing 4 files")
        rig.duplicates.send(.group(one))
        await rig.until { !rig.state.duplicateGroups.isEmpty }
        #expect(rig.state.duplicateGroups == [one])
        #expect(rig.state.isFindingDuplicates)
        rig.duplicates.send(.finished(unreadableFolders: 2, wasCancelled: false))
        await rig.state.waitForDuplicateScan()
        #expect(!rig.state.isFindingDuplicates)
        #expect(rig.state.duplicatePhase == nil)
        #expect(rig.state.hasFoundDuplicates)
        #expect(rig.state.duplicateNotes == ["2 folders could not be read"])
    }

    @Test func aNewerScanReplacesAnOlderOne() async {
        let rig = FilesRig()
        rig.state.startDuplicateScan()
        await rig.duplicates.waitForStarts(1)
        rig.duplicates.send(.group(one))
        await rig.until { !rig.state.duplicateGroups.isEmpty }
        rig.state.startDuplicateScan()
        await rig.duplicates.waitForStarts(2)
        #expect(rig.state.duplicateGroups.isEmpty)
        let newer = FilesRig.group("g2", [FilesRig.file("/h/n1.bin"), FilesRig.file("/h/n2.bin")])
        rig.duplicates.send(.group(newer), scan: 1)
        // The older scan still talks: nothing of it may show.
        rig.duplicates.send(.group(one), scan: 0)
        rig.duplicates.send(.finished(unreadableFolders: 9, wasCancelled: false), scan: 0)
        rig.duplicates.send(.finished(unreadableFolders: 0, wasCancelled: false), scan: 1)
        await rig.state.waitForDuplicateScan()
        #expect(rig.state.duplicateGroups == [newer])
        #expect(rig.state.duplicateUnreadable == 0)
        #expect(!rig.state.isFindingDuplicates)
    }

    @Test func leavingTheScreenStopsTheScanAndKeepsWhatWasFound() async {
        let rig = FilesRig()
        rig.state.startDuplicateScan()
        await rig.duplicates.waitForStarts(1)
        rig.duplicates.send(.group(one))
        await rig.until { !rig.state.duplicateGroups.isEmpty }
        rig.state.cancelWork()
        await rig.state.waitForDuplicateScan()
        #expect(!rig.state.isFindingDuplicates)
        #expect(rig.duplicates.terminated == 1)
        #expect(rig.state.duplicateGroups == [one])
        #expect(rig.state.duplicatesStoppedEarly)
        #expect(rig.state.duplicateNotes == [FilesText.duplicatesStopped])
        rig.duplicates.send(.group(FilesRig.group("late", one.files))) // a late answer changes nothing
        #expect(rig.state.duplicateGroups == [one])
    }

    @Test func aFinishedButCancelledSearchSaysMoreMayExist() async {
        let rig = FilesRig()
        rig.state.startDuplicateScan()
        await rig.duplicates.waitForStarts(1)
        rig.duplicates.send(.finished(unreadableFolders: 0, wasCancelled: true))
        await rig.state.waitForDuplicateScan()
        #expect(rig.state.duplicateNotes == [FilesText.duplicatesStopped])
        #expect(rig.state.duplicatesTotalText.hasPrefix("at least"))
    }

    @Test func stopKeepsTheGroupsAndEndsTheScan() async {
        let rig = FilesRig()
        rig.state.startDuplicateScan()
        await rig.duplicates.waitForStarts(1)
        rig.duplicates.send(.group(one))
        await rig.until { !rig.state.duplicateGroups.isEmpty }
        rig.state.stopDuplicateScan()
        #expect(!rig.state.isFindingDuplicates)
        #expect(rig.state.hasFoundDuplicates)
        #expect(rig.state.duplicateGroups == [one])
    }

    @Test func noScanStartsWhileReviewingOrMoving() async {
        let rig = FilesRig()
        await rig.scanDuplicates([one])
        rig.state.review()
        #expect(rig.state.isReviewing)
        #expect(!rig.state.canStartDuplicateScan)
        #expect(!rig.state.canChangeKeepRule)
        #expect(!rig.state.canStartDiskScan)
        rig.state.startDuplicateScan()
        rig.state.startDiskScan()
        #expect(rig.duplicates.starts == 1)
        #expect(rig.disk.starts == 0)
    }
}

@MainActor
struct FilesTrashStateTests {
    private let older = FilesRig.file("/h/a/x.bin", bytes: 2_000_000, age: 100)
    private let newer = FilesRig.file("/h/b/x.bin", bytes: 2_000_000, age: 0)
    private var group: DuplicateGroup {
        FilesRig.group("g1", [older, newer])
    }

    @Test func reviewNeedsSomethingRemovable() async {
        let rig = FilesRig()
        rig.state.review()
        #expect(!rig.state.isReviewing)
        #expect(rig.state.reviewButtonText == nil)
        await rig.scanDuplicates([group])
        #expect(rig.state.removableFiles == [older])
        #expect(rig.state.reclaimableBytes == 2_000_000)
        #expect(rig.state.reviewButtonText == FilesText.reviewButton(count: 1, bytes: 2_000_000))
        rig.state.review()
        #expect(rig.state.isReviewing)
    }

    @Test func reviewIsRefusedWhileScanning() async {
        let rig = FilesRig()
        rig.state.startDuplicateScan()
        await rig.duplicates.waitForStarts(1)
        rig.duplicates.send(.group(group))
        await rig.until { !rig.state.duplicateGroups.isEmpty }
        rig.state.review()
        #expect(!rig.state.isReviewing)
        rig.state.requestTrash(older)
        #expect(!rig.state.isReviewing)
        rig.state.cancelWork()
    }

    @Test func reviewIsRefusedWhileDiskScanning() {
        let rig = FilesRig()
        rig.state.startDiskScan()
        rig.state.requestTrash(older)
        #expect(!rig.state.isReviewing)
        rig.state.cancelWork()
    }

    @Test func nothingMovesWithoutReview() async {
        let rig = FilesRig()
        await rig.scanDuplicates([group])
        await rig.state.confirm()
        #expect(rig.trasher.calls.isEmpty)
        #expect(rig.state.lastOutcome == nil)
        rig.state.review()
        rig.state.cancelReview()
        await rig.state.confirm()
        #expect(rig.trasher.calls.isEmpty)
        #expect(!rig.state.isReviewing)
    }

    @Test func confirmSendsEachGroupThroughTheDuplicateMove() async {
        let rig = FilesRig()
        let second = FilesRig.group("g2", [
            FilesRig.file("/h/c/y.bin", bytes: 3_000_000, age: 50),
            FilesRig.file("/h/d/y.bin", bytes: 3_000_000, age: 5),
            FilesRig.file("/h/e/y.bin", bytes: 3_000_000, age: 80)
        ], bytes: 3_000_000)
        await rig.scanDuplicates([group, second])
        #expect(rig.state.removableFiles.count == 3)
        #expect(rig.state.reclaimableBytes == 2_000_000 + 6_000_000)
        rig.state.review()
        await rig.state.confirm()
        #expect(rig.trasher.calls.count == 2)
        #expect(rig.trasher.calls.allSatisfy { $0.group != nil })
        #expect(rig.trasher.calls[0].group == group)
        #expect(rig.trasher.calls[0].files == [older])
        #expect(rig.trasher.calls[1].files.map(\.id) == ["/h/c/y.bin", "/h/e/y.bin"])
        #expect(rig.state.duplicateGroups.isEmpty) // each left with one copy
        #expect(!rig.state.isReviewing)
        #expect(!rig.state.isMoving)
        #expect(rig.state.lastOutcome?.moved.count == 3)
    }

    @Test func aSingleFileGoesThroughMoveToTrashAndLeavesEveryList() async {
        let rig = FilesRig()
        let big = FilesRig.file("/h/big.mov", bytes: 60_000_000)
        rig.search.script(FileSearchResult(files: [big, FilesRig.file("/h/keep.txt")], isTruncated: false))
        rig.state.criteria.text = "b"
        await rig.state.searchChanged()
        rig.state.startDiskScan()
        await rig.disk.waitForStarts(1)
        rig.disk.send(.finished(FilesRig.result(files: [big])))
        await rig.state.waitForScan()
        rig.state.requestTrash(big)
        #expect(rig.state.isReviewing)
        #expect(rig.state.removableFiles == [big])
        #expect(rig.state.reclaimableBytes == 60_000_000)
        await rig.state.confirm()
        #expect(rig.trasher.calls == [FakeTrasher.Call(group: nil, files: [big])])
        #expect(rig.state.searchResults.map(\.id) == ["/h/keep.txt"])
        #expect(rig.state.largestFiles.isEmpty)
    }

    @Test func failedFilesStayWithTheirReasonAndCountForNothing() async {
        let rig = FilesRig()
        rig.trasher.refuse(older.id, reason: "It changed since it was found.")
        let third = FilesRig.file("/h/c/x.bin", bytes: 2_000_000, age: 200)
        let big = FilesRig.group("g1", [older, newer, third])
        await rig.scanDuplicates([big])
        rig.state.review()
        await rig.state.confirm()
        // `third` moved, `older` stayed: the group still has two copies.
        #expect(rig.state.duplicateGroups.map { $0.files.map(\.id) } == [[older.id, newer.id]])
        #expect(rig.state.failureReason(for: older) == "It changed since it was found.")
        #expect(rig.state.failureReason(for: newer) == nil)
        #expect(rig.state.lastOutcome?.movedBytes == 2_000_000)
        #expect(rig.state.failureLines == ["x.bin: It changed since it was found."])
    }

    @Test func nothingMovedLeavesGroupsAlone() async {
        let rig = FilesRig()
        rig.trasher.refuse(older.id, reason: "No.")
        await rig.scanDuplicates([group])
        rig.state.review()
        await rig.state.confirm()
        #expect(rig.state.duplicateGroups == [group])
        #expect(rig.state.resultText?.hasPrefix("Nothing was moved.") == true)
    }

    @Test func resultTextCountsOnlyMovedBytesAndCarriesTheCloneNote() async {
        let rig = FilesRig()
        rig.trasher.refuse(older.id, reason: "No.")
        let third = FilesRig.file("/h/c/x.bin", bytes: 1_000_000, age: 200)
        await rig.scanDuplicates([FilesRig.group("g", [older, newer, third], bytes: 1_000_000)])
        rig.state.review()
        await rig.state.confirm()
        let text = rig.state.resultText ?? ""
        #expect(text == "Moved 1 file, about \(formatBytes(1_000_000)), to the Trash. "
            + "Clones share disk space, so moving one may free less than shown. 1 could not be moved.")
    }

    @Test func reviewCopyIsExact() {
        #expect(FilesText.reviewNote == "These files move to the Trash. Space comes back when you empty the Trash. "
            + "Clones share disk space, so moving one may free less than shown.")
    }

    @Test func changingTheKeepRuleWhileReviewingIsIgnored() async {
        let rig = FilesRig()
        await rig.scanDuplicates([group])
        rig.state.review()
        rig.state.keepRule = .oldest
        #expect(rig.state.keepRule == .newest)
        #expect(rig.state.removableFiles == [older])
        await rig.state.confirm()
        #expect(rig.trasher.calls.first?.files == [older])
        rig.state.keepRule = .oldest // allowed again after the move
        #expect(rig.state.keepRule == .oldest)
    }

    @Test func theKeepRuleChangesWhatWouldMove() async {
        let rig = FilesRig()
        await rig.scanDuplicates([group])
        rig.state.keepRule = .oldest
        #expect(rig.state.removableFiles == [newer])
        #expect(rig.state.selection(for: group).kept == older)
        rig.state.keepRule = .shortestPath
        #expect(rig.state.selection(for: group).kept?.id == "/h/a/x.bin")
    }

    @Test func twoCopiesWithIdenticalDatesStillKeepOne() async {
        let rig = FilesRig()
        let first = FilesRig.file("/h/b/x.bin", bytes: 2_000_000)
        let second = FilesRig.file("/h/a/x.bin", bytes: 2_000_000)
        await rig.scanDuplicates([FilesRig.group("g", [first, second])])
        for rule in KeepRule.allCases {
            rig.state.keepRule = rule
            #expect(rig.state.removableFiles.map(\.id) == ["/h/b/x.bin"])
        }
    }

    @Test func reviewAndConfirmAreRefusedWhileMoving() async {
        let gated = GatedTrasher()
        let rig = FilesRig(trasher: gated)
        await rig.scanDuplicates([group])
        rig.state.review()
        let move = Task { await rig.state.confirm() }
        await rig.until { rig.state.isMoving }
        #expect(rig.state.isMoving)
        rig.state.review()
        rig.state.requestTrash(newer)
        #expect(!rig.state.isReviewing)
        await gated.gate.waitForCall()
        gated.gate.release(FileTrashOutcome(moved: [older], failed: []))
        await move.value
        #expect(!rig.state.isMoving)
    }
}

struct FileSizeTextTests {
    @Test func fileSizeTextHandlesZero() {
        #expect(formatFileSize(0) == "Empty")
        #expect(formatFileSize(-5) == "Empty")
        #expect(formatFileSize(1_000_000) != "Empty")
    }
}
