import Foundation
import MainternanceDomain
@testable import MainternancePresentation
import Testing

@MainActor
struct FilesSearchStateTests {
    @Test func allThreeTabsAreShown() {
        #expect(FilesSegment.shown == [.search, .duplicates, .large])
    }

    @Test func searchWaitsThreeHundredMillisecondsBeforeAsking() async {
        let rig = FilesRig()
        rig.state.criteria.text = "report"
        await rig.state.searchChanged()
        #expect(rig.sleepDurations == [.milliseconds(300)])
        #expect(rig.search.queries.count == 1)
    }

    @Test func onlyTheNewestSearchAsks() async {
        let gate = Gate<Void>()
        let rig = FilesRig(sleep: { _ in await gate.wait() })
        rig.state.criteria.text = "a"
        let first = Task { await rig.state.searchChanged() }
        await gate.waitForCall(1)
        rig.state.criteria.text = "ab"
        let second = Task { await rig.state.searchChanged() }
        await gate.waitForCall(2)
        gate.release(())
        gate.release(())
        await first.value
        await second.value
        #expect(rig.search.queries.map(\.text) == ["ab"])
    }

    @Test func anOlderAnswerNeverShowsOverANewerOne() async {
        let gated = GatedFileSearch()
        let rig = FilesRig(search: gated)
        rig.state.criteria.text = "a"
        let first = Task { await rig.state.searchChanged() }
        await gated.gate.waitForCall(1)
        rig.state.criteria.text = "ab"
        let second = Task { await rig.state.searchChanged() }
        await gated.gate.waitForCall(2)
        gated.gate.release(FileSearchResult(files: [FilesRig.file("/h/new.txt")], isTruncated: false), at: 1)
        await second.value
        gated.gate.release(FileSearchResult(files: [FilesRig.file("/h/old.txt")], isTruncated: true), at: 0)
        await first.value
        #expect(rig.state.searchResults.map(\.id) == ["/h/new.txt"])
        #expect(!rig.state.searchIsTruncated)
        #expect(!rig.state.isSearching)
    }

    @Test func anInactiveSearchClearsResultsWithoutAsking() async {
        let rig = FilesRig()
        rig.search.script(FileSearchResult(files: [FilesRig.file("/h/a.txt")], isTruncated: true))
        rig.state.criteria.text = "a"
        await rig.state.searchChanged()
        #expect(rig.state.searchResults.count == 1)
        #expect(rig.state.searchIsTruncated)
        rig.state.criteria = FileSearchCriteria()
        await rig.state.searchChanged()
        #expect(rig.state.searchResults.isEmpty)
        #expect(!rig.state.searchIsTruncated)
        #expect(rig.search.queries.count == 1)
        #expect(rig.sleepDurations.count == 1)
    }

    @Test func criteriaMapToTheQueryWithTheClock() async {
        let rig = FilesRig()
        rig.state.criteria = FileSearchCriteria(text: " report ", kind: .image, size: .over100MB, date: .pastWeek)
        await rig.state.searchChanged()
        let query = rig.search.queries.first
        #expect(query?.text == " report ")
        #expect(query?.kind == .image)
        #expect(query?.minimumBytes == 100_000_000)
        #expect(query?.modifiedAfter == FilesRig.now.addingTimeInterval(-7 * 86400))

        rig.state.criteria = FileSearchCriteria(text: "x")
        await rig.state.searchChanged()
        #expect(rig.search.queries.last?.kind == nil)
        #expect(rig.search.queries.last?.minimumBytes == 0)
        #expect(rig.search.queries.last?.modifiedAfter == nil)
    }

    @Test func aFilterAloneIsAnActiveSearch() async {
        let rig = FilesRig()
        rig.state.criteria.kind = .video
        await rig.state.searchChanged()
        #expect(rig.search.queries.count == 1)
    }

    @Test func spotlightNotAnsweringIsSaidOnlyThen() async {
        let rig = FilesRig()
        rig.state.criteria.text = "a"
        rig.search.script(FileSearchResult(files: [], isTruncated: false))
        await rig.state.searchChanged()
        #expect(!rig.state.searchIsUnavailable)
        #expect(rig.state.searchStatusText == FilesText.noMatches)
        rig.search.script(FileSearchResult(files: [], isTruncated: false, isUnavailable: true))
        await rig.state.searchChanged()
        #expect(rig.state.searchIsUnavailable)
        #expect(rig.state.searchStatusText == "Spotlight did not answer")
        rig.state.criteria = FileSearchCriteria()
        await rig.state.searchChanged()
        #expect(!rig.state.searchIsUnavailable)
        #expect(rig.state.searchStatusText == nil)
    }

    @Test func truncatedResultsSaySo() async {
        let rig = FilesRig()
        rig.state.criteria.text = "a"
        rig.search.script(FileSearchResult(files: [FilesRig.file("/h/a")], isTruncated: true))
        await rig.state.searchChanged()
        #expect(rig.state.searchTruncatedText == FilesText.truncated)
        rig.search.script(FileSearchResult(files: [FilesRig.file("/h/a")], isTruncated: false))
        await rig.state.searchChanged()
        #expect(rig.state.searchTruncatedText == nil)
    }

    @Test func theSpotlightCopyIsExact() {
        #expect(FilesText.spotlightNote
            == "Spotlight results: files Spotlight has not indexed will not appear. Files only.")
    }

    @Test func cancelWorkMakesALateSearchAnswerHarmless() async {
        let gated = GatedFileSearch()
        let rig = FilesRig(search: gated)
        rig.state.criteria.text = "a"
        let running = Task { await rig.state.searchChanged() }
        await gated.gate.waitForCall(1)
        #expect(rig.state.isSearching)
        rig.state.cancelWork()
        #expect(!rig.state.isSearching)
        gated.gate.release(FileSearchResult(files: [FilesRig.file("/h/late")], isTruncated: false))
        await running.value
        #expect(rig.state.searchResults.isEmpty)
    }

    @Test func quickLookAndRevealGetTheRealUncleanedPath() {
        let rig = FilesRig()
        let path = "/h/evil\u{202E}name\ntxt"
        let file = FilesRig.file(path)
        rig.state.quickLook(file)
        rig.state.reveal(file)
        #expect(rig.recorder.quickLooked == [path])
        #expect(rig.recorder.revealed == [path])
        #expect(file.displayPath != path) // cleaning is for showing only
    }
}

@MainActor
struct FilesLargeStateTests {
    @Test func appearOnSearchStartsNothing() async {
        let rig = FilesRig()
        await rig.state.appear()
        #expect(rig.disk.starts == 0)
        #expect(!rig.state.isScanningDisk)
    }

    @Test func largeFilesStartsOnFirstOpenAndNeverTwiceWhileRunning() async {
        let rig = FilesRig()
        rig.state.segment = .large
        await rig.state.appear()
        await rig.state.appear()
        rig.state.startDiskScan()
        #expect(rig.disk.starts == 1)
        #expect(rig.state.isScanningDisk)
    }

    @Test func aFinishedScanIsNotRepeatedOnReopen() async {
        let rig = FilesRig()
        rig.state.segment = .large
        await rig.state.appear()
        rig.disk.send(.finished(FilesRig.result()))
        await rig.state.waitForScan()
        await rig.state.appear()
        #expect(rig.disk.starts == 1)
        rig.state.startDiskScan() // the button scans again on demand
        #expect(rig.disk.starts == 2)
    }

    @Test func progressAndResultFillTheState() async {
        let rig = FilesRig()
        rig.state.startDiskScan()
        await rig.disk.waitForStarts(1)
        rig.disk.send(.progress(scannedFiles: 1200))
        while rig.state.scanProgress != 1200 {
            await Task.yield()
        }
        #expect(rig.state.scanProgressText == "Scanned \(1200.formatted()) files")
        rig.disk.send(.finished(FilesRig.result()))
        await rig.state.waitForScan()
        #expect(rig.state.diskResult == FilesRig.result())
        #expect(!rig.state.isScanningDisk)
        #expect(rig.state.scanProgressText == nil)
        #expect(rig.state.largestFiles.map(\.id) == ["/h/a/f"])
    }

    @Test func drillDownUsesTheTreeRules() async {
        let rig = FilesRig()
        rig.state.startDiskScan()
        await rig.disk.waitForStarts(1)
        rig.disk.send(.finished(FilesRig.result()))
        await rig.state.waitForScan()
        let state = rig.state
        #expect(state.currentNode.id == "/h")
        state.drillInto("/h/p.app") // package
        state.drillInto("/h/x") // plain file
        state.drillInto("/h\0other") // Other
        state.drillInto("/missing")
        #expect(state.breadcrumb.map(\.id) == ["/h"])
        state.drillInto("/h/a")
        #expect(state.breadcrumb.map(\.id) == ["/h", "/h/a"])
        state.drillInto("/h/a/f") // empty file node: not drillable
        #expect(state.currentNode.id == "/h/a")
        state.goUp()
        #expect(state.currentNode.id == "/h")
        state.goUp()
        #expect(state.currentNode.id == "/h")
        state.drillInto("/h/a")
        state.jump(toDepth: 99)
        #expect(state.currentNode.id == "/h/a")
        state.jump(toDepth: -3)
        #expect(state.currentNode.id == "/h")
    }

    @Test func aNewResultReturnsTheTreemapToTheTop() async {
        let rig = FilesRig()
        rig.state.startDiskScan()
        await rig.disk.waitForStarts(1)
        rig.disk.send(.finished(FilesRig.result()))
        await rig.state.waitForScan()
        rig.state.drillInto("/h/a")
        rig.state.startDiskScan()
        await rig.disk.waitForStarts(2)
        rig.disk.send(.finished(FilesRig.result()), scan: 1)
        await rig.state.waitForScan()
        #expect(rig.state.breadcrumb.map(\.id) == ["/h"])
    }

    @Test func aCancelledScanKeepsThePreviousResult() async {
        let rig = FilesRig()
        rig.state.startDiskScan()
        await rig.disk.waitForStarts(1)
        let first = FilesRig.result(files: [FilesRig.file("/h/first", bytes: 60_000_000)])
        rig.disk.send(.finished(first))
        await rig.state.waitForScan()

        rig.state.startDiskScan()
        await rig.disk.waitForStarts(2)
        rig.state.cancelWork()
        #expect(!rig.state.isScanningDisk)
        rig.disk.send(.finished(FilesRig.result(cancelled: true)), scan: 1)
        await rig.state.waitForScan()
        #expect(rig.state.diskResult == first)
        #expect(!rig.state.isScanningDisk)
    }

    @Test func aResultMarkedCancelledIsNeverShown() async {
        let rig = FilesRig()
        rig.state.startDiskScan()
        await rig.disk.waitForStarts(1)
        rig.disk.send(.finished(FilesRig.result(cancelled: true)))
        await rig.state.waitForScan()
        #expect(rig.state.diskResult == nil)
        #expect(!rig.state.isScanningDisk)
    }

    @Test func cancelWorkStopsTheConsumerOfTheScan() async {
        let rig = FilesRig()
        rig.state.startDiskScan()
        await rig.disk.waitForStarts(1)
        rig.state.cancelWork()
        await rig.state.waitForScan()
        #expect(rig.disk.terminated == 1)
        rig.state.startDiskScan() // can scan again afterwards
        #expect(rig.disk.starts == 2)
    }

    @Test func aStreamThatEndsWithoutAResultStopsScanning() async {
        let rig = FilesRig()
        rig.state.startDiskScan()
        await rig.disk.waitForStarts(1)
        rig.disk.finish()
        await rig.state.waitForScan()
        #expect(!rig.state.isScanningDisk)
        #expect(rig.state.diskResult == nil)
    }

    @Test func unreadableFoldersAreNotedAndTotalsAreAtLeast() async {
        let rig = FilesRig()
        rig.state.startDiskScan()
        await rig.disk.waitForStarts(1)
        rig.disk.send(.finished(FilesRig.result(unreadable: 3)))
        await rig.state.waitForScan()
        #expect(rig.state.unreadableNote == "3 folders could not be read")
        #expect(rig.state.totalText.hasPrefix("at least"))

        rig.state.startDiskScan()
        await rig.disk.waitForStarts(2)
        rig.disk.send(.finished(FilesRig.result(unreadable: 1)), scan: 1)
        await rig.state.waitForScan()
        #expect(rig.state.unreadableNote == "1 folder could not be read")

        rig.state.startDiskScan()
        await rig.disk.waitForStarts(3)
        rig.disk.send(.finished(FilesRig.result(unreadable: 0)), scan: 2)
        await rig.state.waitForScan()
        #expect(rig.state.unreadableNote == nil)
        #expect(rig.state.totalText.hasPrefix("about"))
    }
}
