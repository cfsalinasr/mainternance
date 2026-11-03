import Foundation
import MainternanceDomain
@testable import MainternancePresentation
import Testing

@MainActor
@Suite("Cleanup screen state")
struct CleanupViewStateTests {
    private let big = CleanupRig.path("big")
    private let small = CleanupRig.path("small")
    private let log = CleanupRig.path("app.log", folder: "/Users/me/Library/Logs")

    @Test("nothing is shown or selected before the first measuring")
    func startsEmpty() {
        let rig = CleanupRig()
        #expect(rig.state.measurement == nil)
        #expect(rig.state.selectedEntries.isEmpty)
        #expect(!rig.state.canReview)
        #expect(!rig.state.showsMeasuring)
        #expect(rig.fake.measures == 0) // building the state never walks the disk
    }

    @Test("measuring fills the categories with every entry selected and reports the measurement")
    func measureSelectsAll() async {
        let rig = CleanupRig()
        await rig.state.measure()
        #expect(rig.state.measurement == CleanupRig.sample)
        #expect(rig.state.selectedEntries.map(\.id) == [big, small, log])
        #expect(rig.state.selectedBytes == 3250 * CleanupRig.megabyte)
        #expect(rig.state.isSelected(category: .caches))
        #expect(rig.state.selectionText(CleanupRig.sample.categories[0]) == "2 of 2 selected")
        let cachesSize = formatBytes(3200 * CleanupRig.megabyte)
        #expect(rig.state.sizeText(CleanupRig.sample.categories[0]) == "about \(cachesSize)")
        #expect(rig.reported.all == [CleanupRig.sample])
        #expect(rig.state.canReview)
        #expect(!rig.state.isMeasuring)
    }

    @Test("toggling a category clears all its entries, toggling again selects them all")
    func toggleCategory() async {
        let rig = CleanupRig()
        await rig.state.measure()
        rig.state.toggleCategory(.caches)
        #expect(rig.state.selectedEntries.map(\.id) == [log])
        #expect(!rig.state.isSelected(category: .caches))
        rig.state.toggleEntry(small)
        #expect(!rig.state.isSelected(category: .caches)) // only part of it
        rig.state.toggleCategory(.caches)
        #expect(rig.state.selectedEntries.map(\.id) == [big, small, log])
    }

    @Test("a single entry can be unticked and ticked again; unknown ids do nothing")
    func toggleEntry() async {
        let rig = CleanupRig()
        await rig.state.measure()
        rig.state.toggleEntry(big)
        #expect(!rig.state.isSelected(entry: big))
        #expect(rig.state.selectedBytes == 250 * CleanupRig.megabyte)
        rig.state.toggleEntry("/nowhere")
        #expect(rig.state.selectedEntries.count == 2)
        rig.state.toggleEntry(big)
        #expect(rig.state.isSelected(entry: big))
    }

    @Test("review opens only when something is selected")
    func reviewNeedsSelection() async {
        let rig = CleanupRig()
        rig.state.review()
        #expect(!rig.state.isReviewing)
        await rig.state.measure()
        for kind in [CleanupKind.caches, .logs] {
            rig.state.toggleCategory(kind)
        }
        rig.state.review()
        #expect(!rig.state.isReviewing)
        rig.state.toggleEntry(log)
        rig.state.review()
        #expect(rig.state.isReviewing)
        rig.state.cancelReview()
        #expect(!rig.state.isReviewing)
    }

    @Test("nothing is moved without the review step")
    func confirmNeedsReview() async {
        let rig = CleanupRig()
        await rig.state.measure()
        await rig.state.confirm()
        #expect(rig.fake.moves.isEmpty)
        #expect(rig.state.lastOutcome == nil)
    }

    @Test("confirm moves exactly the selected entries and removes them from the list")
    func confirmMovesSelected() async {
        let rig = CleanupRig()
        await rig.state.measure()
        rig.state.toggleEntry(small)
        rig.state.review()
        await rig.state.confirm()
        #expect(rig.fake.moves == [[big, log]])
        #expect(!rig.state.isReviewing)
        #expect(!rig.state.isMoving)
        #expect(rig.state.measurement?.categories.flatMap(\.entries).map(\.id) == [small])
        #expect(rig.state.lastOutcome?.moved.map(\.id) == [big, log])
        #expect(rig.state.selectedEntries.isEmpty)
        #expect(rig.reported.all.last?.totalBytes == 200 * CleanupRig.megabyte) // Home's estimate drops at once
        let freed = formatBytes(3050 * CleanupRig.megabyte) // the decimal separator follows the locale
        #expect(rig.state.resultText == "Moved 2 items, about \(freed), to the Trash.")
        #expect(rig.state.message == nil)
    }

    @Test("a failed entry stays listed with its reason and is never counted as freed")
    func partialFailure() async {
        let rig = CleanupRig()
        rig.fake.configure { $0.failing = [big: "It is in use."] }
        await rig.state.measure()
        rig.state.review()
        await rig.state.confirm()
        #expect(rig.state.measurement?.categories.flatMap(\.entries).map(\.id) == [big])
        #expect(rig.state.failureReason(big) == "It is in use.")
        #expect(rig.state.failureReason(small) == nil)
        #expect(rig.state.lastOutcome?.movedBytes == 250 * CleanupRig.megabyte)
        #expect(rig.state.resultText == "Moved 2 items, about 250 MB, to the Trash. 1 could not be moved.")
        #expect(rig.state.failureLines == ["big: It is in use."])
    }

    @Test("a mover that fails everything leaves the list as it was and shows the reasons")
    func everythingFails() async {
        let rig = CleanupRig()
        rig.fake.configure { $0.failing = [big: "No.", small: "No.", log: "No."] }
        await rig.state.measure()
        rig.state.review()
        await rig.state.confirm()
        #expect(rig.state.measurement == CleanupRig.sample)
        #expect(rig.state.lastOutcome?.movedBytes == 0)
        #expect(rig.state.message == CleanupText.nothingMoved)
        #expect(rig.state.failureLines.count == 3)
        #expect(rig.reported.all.count == 1) // nothing changed, nothing reported again
    }

    @Test("overlapping measurings show the newest, whatever order they finish in")
    func newestMeasurementWins() async {
        let gate = GatedCleanupScanner()
        let rig = CleanupRig(scanner: gate)
        let older = Task { await rig.state.measure() }
        await gate.waitForCall(1)
        let newer = Task { await rig.state.measure() }
        await gate.waitForCall(2)
        let newest = CleanupMeasurement(categories: [], measuredAt: Date(timeIntervalSince1970: 2))
        gate.release(newest, at: 1)
        await newer.value
        gate.release(CleanupRig.sample, at: 0)
        await older.value
        #expect(rig.state.measurement == newest)
        #expect(rig.reported.all == [newest])
        #expect(!rig.state.isMeasuring)
    }

    @Test("the spinner shows only while nothing was measured yet")
    func spinnerOnlyFirstTime() async {
        let gate = GatedCleanupScanner()
        let rig = CleanupRig(scanner: gate)
        let first = Task { await rig.state.measure() }
        await gate.waitForCall(1)
        #expect(rig.state.showsMeasuring)
        #expect(rig.state.isMeasuring)
        #expect(!rig.state.canReview)
        gate.release(CleanupRig.sample)
        await first.value
        let second = Task { await rig.state.measure() }
        await gate.waitForCall(1)
        #expect(!rig.state.showsMeasuring)
        #expect(!rig.state.canReview) // nothing is reviewed while a measuring runs
        gate.release(CleanupRig.sample)
        await second.value
    }

    @Test("appearing measures, but not again while a measuring runs")
    func appearMeasures() async {
        let rig = CleanupRig()
        await rig.state.appear()
        #expect(rig.fake.measures == 1)
        #expect(rig.state.measurement != nil)
        let gate = GatedCleanupScanner()
        let gated = CleanupRig(scanner: gate)
        let first = Task { await gated.state.appear() }
        await gate.waitForCall(1)
        await gated.state.appear() // returns at once: the first measuring is still running
        gate.release(CleanupRig.sample)
        await first.value
        #expect(gated.state.measurement == CleanupRig.sample)
        #expect(gated.reported.all.count == 1)
    }

    @Test("measuring while moving is ignored")
    func measureWhileMovingIgnored() async {
        let gate = GatedMover()
        let fake = FakeCleanup()
        let state = CleanupViewState(scanner: fake, mover: gate)
        await state.measure()
        state.review()
        let moving = Task { await state.confirm() }
        await gate.waitForCall()
        #expect(state.isMoving)
        await state.measure()
        #expect(fake.measures == 1)
        state.review()
        #expect(!state.isReviewing)
        gate.release(CleanupOutcome(moved: [], failed: []))
        await moving.value
        #expect(!state.isMoving)
    }

    @Test("sizes read as about, or at least when part could not be read")
    func sizeText() {
        let exact = CleanupCategory(kind: .caches, entries: [CleanupRig.entry("a", 4200)])
        let partial = CleanupCategory(kind: .caches, entries: [CleanupRig.entry("a", 4200, lowerBound: true)])
        let shown = formatBytes(4200 * CleanupRig.megabyte)
        #expect(CleanupText.size(exact) == "about \(shown)")
        #expect(CleanupText.size(partial) == "at least \(shown)")
        #expect(CleanupText.size(CleanupRig.entry("b", 12)) == "about 12 MB")
    }

    @Test("names are shown cleaned, with their folder")
    func shortPath() {
        let odd = CleanupRig.entry("bad\u{202E}name\nx", 1)
        #expect(CleanupText.shortPath(odd, kind: .caches) == "~/Library/Caches/badname x")
        #expect(CleanupText.shortPath(odd, kind: .installers) == "~/Downloads/badname x")
        #expect(CleanupText.subtitle(odd, kind: .caches) == "~/Library/Caches/badname x · Folder")
    }

    @Test("folders that could not be opened are noted")
    func unreadableNotes() async {
        let measurement = CleanupMeasurement(
            categories: [], measuredAt: Date(timeIntervalSince1970: 0), unreadable: [.logs]
        )
        let rig = CleanupRig(measurement)
        await rig.state.measure()
        #expect(rig.state.notes == ["Could not open ~/Library/Logs, so it is not measured."])
        #expect(rig.state.showsNothingFound)
        #expect(rig.state.sizeText(CleanupCategory(kind: .logs, entries: [])) == CleanupText.emptyCategory)
        #expect(!rig.state.canToggle(CleanupCategory(kind: .logs, entries: [])))
    }

    @Test("every category has a name, a description and an icon; the screen's sentences are pinned")
    func pinnedText() {
        for kind in CleanupKind.allCases {
            #expect(!CleanupText.title(kind).isEmpty)
            #expect(!CleanupText.detail(kind).isEmpty)
            #expect(!CleanupText.symbol(kind).isEmpty)
        }
        #expect(CleanupText.title(.developer) == "Developer build caches")
        #expect(CleanupText.reviewNote == [
            "These items move to the Trash. Space comes back when you empty the Trash.",
            "Quit apps before cleaning their caches."
        ].joined(separator: " "))
    }
}
