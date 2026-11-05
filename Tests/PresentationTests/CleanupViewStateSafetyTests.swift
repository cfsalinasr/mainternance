import Foundation
import MainternanceDomain
@testable import MainternancePresentation
import Testing

/// What keeps the Cleanup screen from cleaning the wrong thing: default ticks, dropped cancelled measurings, no
/// measuring during the review, out-of-date lists, and honest result sizes.
@MainActor
@Suite("Cleanup screen safety")
struct CleanupViewStateSafetyTests {
    private let big = CleanupRig.path("big")
    private let small = CleanupRig.path("small")
    private let log = CleanupRig.path("app.log", folder: "/Users/me/Library/Logs")

    @Test("old installers start unticked; caches and logs start ticked")
    func installersStartUnticked() async {
        let rig = CleanupRig(CleanupRig.withInstaller)
        await rig.state.measure()
        let installer = CleanupRig.path("Old.dmg", folder: CleanupRig.downloads)
        #expect(rig.state.selectedEntries.map(\.id) == [big, small, log])
        #expect(!rig.state.isSelected(entry: installer))
        #expect(rig.state.selectionText(CleanupRig.withInstaller.categories[2]) == "0 of 1 selected")
        rig.state.toggleEntry(installer)
        #expect(rig.state.isSelected(entry: installer))
        await rig.state.measure() // the owner ticked it: a new measuring keeps that choice
        #expect(rig.state.isSelected(entry: installer))
    }

    @Test("a measuring cancelled by leaving the screen is dropped: the previous list stays and Home is not told")
    func cancelledMeasureDropped() async {
        let gate = GatedCleanupScanner()
        let rig = CleanupRig(scanner: gate)
        let first = Task { await rig.state.measure() }
        await gate.waitForCall(1)
        gate.release(CleanupRig.sample)
        await first.value
        rig.state.toggleEntry(small)
        let leaving = Task { await rig.state.measure() }
        await gate.waitForCall(1)
        leaving.cancel()
        let partial = CleanupMeasurement(
            categories: [CleanupCategory(kind: .caches, entries: [CleanupRig.entry("big", 1, lowerBound: true)])],
            measuredAt: Date(timeIntervalSince1970: 5)
        )
        gate.release(partial)
        await leaving.value
        #expect(rig.state.measurement == CleanupRig.sample)
        #expect(rig.reported.all == [CleanupRig.sample])
        #expect(!rig.state.isSelected(entry: small)) // the selection is kept too
        #expect(!rig.state.isMeasuring)
    }

    @Test("a cancelled first measuring leaves the screen unmeasured")
    func cancelledFirstMeasureDropped() async {
        let gate = GatedCleanupScanner()
        let rig = CleanupRig(scanner: gate)
        let leaving = Task { await rig.state.measure() }
        await gate.waitForCall(1)
        leaving.cancel()
        gate.release(CleanupRig.sample)
        await leaving.value
        #expect(rig.state.measurement == nil)
        #expect(rig.reported.all.isEmpty)
    }

    @Test("measuring is refused while the review is open, so unticked entries stay unticked")
    func noMeasureWhileReviewing() async {
        let rig = CleanupRig()
        await rig.state.measure()
        rig.state.toggleEntry(small)
        rig.state.review()
        #expect(!rig.state.canMeasure)
        await rig.state.measure()
        await rig.state.appear()
        #expect(rig.fake.measures == 1)
        #expect(!rig.state.isSelected(entry: small))
        #expect(rig.state.isReviewing)
        await rig.state.confirm()
        #expect(rig.fake.moves == [[big, log]])
    }

    @Test("a list older than 5 minutes is not cleaned: measure again first")
    func staleListRefused() async {
        let rig = CleanupRig()
        await rig.state.measure()
        rig.clock.advance(301)
        rig.state.review()
        await rig.state.confirm()
        #expect(rig.fake.moves.isEmpty)
        #expect(!rig.state.isReviewing)
        #expect(rig.state.message == "The list is out of date: measure again before cleaning.")
        #expect(rig.state.lastOutcome == nil)
        #expect(rig.state.showsResultCard) // The refusal must be visible even with no earlier result.
        await rig.state.measure()
        #expect(rig.state.message == nil)
        rig.state.review()
        await rig.state.confirm()
        #expect(rig.fake.moves == [[big, small, log]])
    }

    @Test("a list just under 5 minutes old is cleaned; a clock that went backwards counts as out of date")
    func freshEnoughList() async {
        let rig = CleanupRig()
        await rig.state.measure()
        rig.clock.advance(299)
        rig.state.review()
        await rig.state.confirm()
        #expect(rig.fake.moves.count == 1)
        let backwards = CleanupRig()
        await backwards.state.measure()
        backwards.clock.advance(-60)
        backwards.state.review()
        await backwards.state.confirm()
        #expect(backwards.fake.moves.isEmpty)
        #expect(backwards.state.message == CleanupText.outOfDate)
    }

    @Test("the result says at least when any moved item was only partly measured")
    func resultLowerBound() {
        let exact = CleanupOutcome(moved: [CleanupRig.entry("a", 12)], failed: [])
        #expect(CleanupText.result(exact) == "Moved 1 item, about 12 MB, to the Trash.")
        let partial = CleanupOutcome(
            moved: [CleanupRig.entry("a", 12), CleanupRig.entry("b", 3, lowerBound: true)],
            failed: [CleanupFailure(entry: CleanupRig.entry("c", 1), reason: "No.")]
        )
        #expect(CleanupText.result(partial) == "Moved 2 items, at least 15 MB, to the Trash. 1 could not be moved.")
    }
}
