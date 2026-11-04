import Foundation
import MainternanceDomain
@testable import MainternancePresentation
import Testing

/// Findings of the final branch review: stale results, in-flight lookups and raw paths.
@MainActor
struct UninstallerFinalFixTests {
    typealias Rig = UninstallerRig

    private func move(_ state: UninstallerViewState) async {
        state.review()
        await state.confirm()
    }

    @Test func selectingAnotherAppClearsTheLastResult() async {
        let rig = Rig()
        await rig.state.appear()
        await rig.state.select(Rig.photo.id)
        await move(rig.state)
        #expect(rig.state.lastOutcome != nil)
        await rig.state.select(Rig.notes.id)
        #expect(rig.state.lastOutcome == nil)
        #expect(!rig.state.showsResultCard)
        #expect(rig.state.resultText == nil)
        #expect(rig.state.failureLines.isEmpty)
    }

    @Test func selectingTheSameAppAgainKeepsItsResult() async {
        let rig = Rig()
        rig.fake.configure { $0.failing[Rig.photoCache.id] = "No." }
        await rig.state.appear()
        await rig.state.select(Rig.photo.id)
        await move(rig.state)
        await rig.state.select(Rig.photo.id)
        #expect(rig.state.lastOutcome != nil)
    }

    @Test func clearingTheSelectionDropsALookupStillInFlight() async {
        let finder = GatedFinder()
        let fake = FakeUninstaller()
        let state = UninstallerViewState(lister: fake, finder: finder, mover: fake)
        await state.appear()
        let lookup = Task { await state.select(Rig.photo.id) }
        await finder.gate.waitForCall(1)
        // The app is no longer listed: appear() clears the selection.
        fake.configure { $0.apps = [Rig.notes] }
        await state.appear()
        #expect(state.selectedID == nil)
        finder.gate.release(Rig.photoDetails, at: 0)
        await lookup.value
        #expect(state.details == nil)
        #expect(state.selectedID == nil)
        #expect(!state.isLoadingDetails)
        #expect(!state.canReview)
    }

    @Test func aCancelledLookupDoesNotApply() async {
        let finder = GatedFinder()
        let fake = FakeUninstaller()
        let state = UninstallerViewState(lister: fake, finder: finder, mover: fake)
        await state.appear()
        let lookup = Task { await state.select(Rig.photo.id) }
        await finder.gate.waitForCall(1)
        lookup.cancel()
        finder.gate.release(Rig.photoDetails, at: 0)
        await lookup.value
        #expect(state.details == nil)
        #expect(!state.isLoadingDetails)
    }

    @Test func startSelectCancelsThePreviousLookup() async {
        let finder = GatedFinder()
        let fake = FakeUninstaller()
        let state = UninstallerViewState(lister: fake, finder: finder, mover: fake)
        await state.appear()
        state.startSelect(Rig.photo.id)
        await finder.gate.waitForCall(1)
        state.startSelect(Rig.notes.id)
        await finder.gate.waitForCall(2)
        finder.gate.release(Rig.photoDetails, at: 0)
        finder.gate.release(Rig.notesDetails, at: 0)
        while state.isLoadingDetails {
            await Task.yield()
        }
        #expect(state.selectedID == Rig.notes.id)
        #expect(state.details == Rig.notesDetails)
    }

    @Test func confirmMovesTheRefreshedAppFromDetails() async {
        let finder = GatedFinder()
        let fake = FakeUninstaller()
        let state = UninstallerViewState(lister: fake, finder: finder, mover: fake)
        await state.appear()
        let lookup = Task { await state.select(Rig.photo.id) }
        await finder.gate.waitForCall(1)
        let refreshed = InstalledApp(
            path: Rig.photo.id, name: "Photo Studio", bundleID: "com.example.photo", version: "2.2",
            identity: CleanupEntry.Identity(device: 1, inode: 99)
        )
        finder.gate.release(
            AppDetails(app: refreshed, appBytes: 1, appIsLowerBound: false, leftovers: []), at: 0
        )
        await lookup.value
        #expect(state.details?.app.identity == refreshed.identity)
        state.review()
        await state.confirm()
        #expect(fake.moves.first?.appID == Rig.photo.id)
    }

    @Test func appPathIsCleanedOfBidiOverrides() {
        let app = InstalledApp(
            path: "/Applications/\u{202E}gpj.Evil.app", name: "Evil", bundleID: nil, version: nil
        )
        let shown = UninstallerText.appPath(app)
        #expect(!shown.unicodeScalars.contains("\u{202E}"))
        #expect(shown == DisplayText.clean(app.id))
        #expect(shown.hasPrefix("/Applications/"))
    }
}
