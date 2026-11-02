import Foundation
import MainternanceDomain
@testable import MainternancePresentation
import Testing

/// Saving the review, the last action's message and the first-reading spinner.
@MainActor
@Suite("Startup screen review and messages")
struct StartupReviewStateTests {
    private let updater = "/Users/me/Library/LaunchAgents/com.example.updater.plist"

    @Test("Mark all as reviewed is not offered while the review cannot be read or saved")
    func markReviewedNeedsAWritableReview() async {
        var unreadable = StartupRig.sample
        unreadable.reviewUnreadable = true
        var readOnly = StartupRig.sample
        readOnly.reviewReadOnly = true
        for snapshot in [unreadable, readOnly] {
            let rig = StartupRig(snapshot)
            await rig.state.refresh()
            #expect(!rig.state.canMarkReviewed)
            await rig.state.markAllReviewed()
            #expect(rig.fake.reviewed.isEmpty)
        }
        let rig = StartupRig(readOnly)
        await rig.state.refresh()
        #expect(rig.state.baselineNote == StartupText.reviewNotSaved)
        #expect(StartupText.reviewNotSaved
            == "Your review could not be saved, so nothing will be marked as new. Mark all as reviewed is off.")
    }

    @Test("a review that fails to save says so, and the New badges stay")
    func failedReviewSays() async {
        let rig = StartupRig()
        rig.fake.configure { $0.reviewSaves = false }
        await rig.state.refresh()
        await rig.state.markAllReviewed()
        #expect(rig.fake.reviewed.count == 1)
        #expect(rig.state.message == StartupText.reviewSaveFailed)
        #expect(rig.state.message == "Could not save your review, so nothing changed.")
        #expect(rig.state.snapshot?.items.contains(where: \.isNew) == true)
    }

    @Test("the last action's message clears on the next refresh or action")
    func messageClears() async {
        let rig = StartupRig()
        await rig.state.refresh()
        await rig.state.setEnabled(updater, false)
        #expect(rig.state.message == StartupText.takesEffect)
        await rig.state.refresh()
        #expect(rig.state.message == nil)
        rig.fake.configure { $0.reviewSaves = false }
        await rig.state.markAllReviewed()
        #expect(rig.state.message == StartupText.reviewSaveFailed)
        rig.fake.configure { $0.reviewSaves = true }
        await rig.state.markAllReviewed()
        #expect(rig.state.message == nil)
        await rig.state.setEnabled(updater, true)
        #expect(rig.state.message == StartupText.takesEffect)
        rig.fake.configure { $0.controlError = .failed("no") }
        await rig.state.setEnabled(updater, false)
        #expect(rig.state.message == "macOS could not change it: no")
        rig.fake.configure { $0.controlError = nil }
        await rig.state.markAllReviewed()
        #expect(rig.state.message == nil)
    }

    @Test("the spinner shows only while the first reading is in flight")
    func spinner() async {
        let gate = GatedListing()
        let fake = FakeStartup()
        let state = StartupViewState(lister: gate, controller: fake, reviewer: fake, reveal: { _ in })
        #expect(!state.showsLoading)
        let first = Task { await state.refresh() }
        await gate.waitForCall()
        #expect(state.showsLoading)
        gate.release(StartupRig.sample)
        await first.value
        #expect(!state.showsLoading)
        let second = Task { await state.refresh() }
        await gate.waitForCall()
        #expect(state.isLoading)
        #expect(!state.showsLoading) // a later reading keeps the rows on screen
        gate.release(StartupRig.sample)
        await second.value
    }
}
