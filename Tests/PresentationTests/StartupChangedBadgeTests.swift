import Foundation
import MainternanceDomain
@testable import MainternancePresentation
import Testing

/// A changed item is marked in words ("Changed", "Changed since your last review"), never like a reviewed one.
@MainActor
struct StartupChangedBadgeTests {
    @Test func aChangedItemGetsTheChangedBadgeAndNote() {
        let rig = StartupRig()
        var item = StartupRig.item("com.google.keystone.agent")
        item.isChanged = true
        let badge = rig.state.badge(item)
        #expect(badge?.text == "Changed")
        #expect(badge?.accessibility == "Changed since your last review")
        #expect(rig.state.rowNotes(item).contains(StartupText.changedNote))
        #expect(StartupText.changedNote.hasPrefix("Changed since your last review"))
        #expect(item.needsReview)
    }

    @Test func aNewItemKeepsTheNewBadge() {
        let rig = StartupRig()
        let item = StartupRig.item("com.example.new", isNew: true)
        #expect(rig.state.badge(item)?.text == StartupText.newBadge)
        #expect(!rig.state.rowNotes(item).contains(StartupText.changedNote))
    }

    @Test func aReviewedItemHasNoBadge() {
        let rig = StartupRig()
        let item = StartupRig.item("com.example.seen")
        #expect(rig.state.badge(item) == nil)
        #expect(!item.needsReview)
    }
}
