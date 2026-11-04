import Foundation
import MainternanceDomain
@testable import MainternancePresentation
import Testing

@MainActor
struct UninstallerViewStateTests {
    typealias Rig = UninstallerRig

    private func selected(_ rig: Rig = Rig()) async -> Rig {
        await rig.state.appear()
        await rig.state.select(Rig.photo.id)
        return rig
    }

    @Test func appearListsAppsAndSelectsNothing() async {
        let rig = Rig()
        await rig.state.appear()
        #expect(rig.state.apps == Rig.apps)
        #expect(rig.state.selectedID == nil)
        #expect(rig.state.details == nil)
        #expect(!rig.state.isListing)
    }

    @Test func selectTicksTheAppAndStrongMatchesOnly() async {
        let rig = await selected()
        #expect(rig.state.details == Rig.photoDetails)
        #expect(rig.state.includesApp)
        #expect(rig.state.isSelected(leftover: Rig.photoCache.id))
        #expect(rig.state.isSelected(leftover: Rig.photoSupport.id))
        #expect(!rig.state.isSelected(leftover: Rig.photoByName.id))
        #expect(!rig.state.isSelected(leftover: Rig.photoAgent.id))
        #expect(rig.state.selectedBytes == (500 + 800 + 200) * Rig.megabyte)
    }

    @Test func unknownIdClearsTheSelection() async {
        let rig = await selected()
        await rig.state.select("nope")
        #expect(rig.state.selectedID == nil)
        #expect(rig.state.details == nil)
        #expect(!rig.state.canReview)
    }

    @Test func quickSuccessiveSelectsKeepOnlyTheNewestApp() async {
        let finder = GatedFinder()
        let fake = FakeUninstaller()
        let state = UninstallerViewState(lister: fake, finder: finder, mover: fake)
        await state.appear()
        let first = Task { await state.select(Rig.photo.id) }
        await finder.gate.waitForCall(1)
        let second = Task { await state.select(Rig.notes.id) }
        await finder.gate.waitForCall(2)
        finder.gate.release(Rig.notesDetails, at: 1)
        await second.value
        finder.gate.release(Rig.photoDetails, at: 0)
        await first.value
        #expect(state.selectedID == Rig.notes.id)
        #expect(state.details == Rig.notesDetails)
        #expect(!state.isLoadingDetails)
    }

    @Test func searchFiltersByNameIgnoringCase() async {
        let rig = Rig()
        await rig.state.appear()
        rig.state.searchText = "PHOTO"
        #expect(rig.state.visibleApps == [Rig.photo])
        rig.state.searchText = "  "
        #expect(rig.state.visibleApps == Rig.apps)
        rig.state.searchText = "zzz"
        #expect(rig.state.visibleApps.isEmpty)
    }

    @Test func reviewNeedsSomethingTicked() async {
        let rig = await selected()
        rig.state.review()
        #expect(rig.state.isReviewing)
        rig.state.cancelReview()
        rig.state.toggleApp()
        for item in [Rig.photoSupport, Rig.photoCache] {
            rig.state.toggleLeftover(item.id)
        }
        #expect(!rig.state.canReview)
        rig.state.review()
        #expect(!rig.state.isReviewing)
        rig.state.toggleLeftover(Rig.photoByName.id)
        #expect(rig.state.canReview)
    }

    @Test func reviewIsRefusedWhileLoading() async {
        let finder = GatedFinder()
        let fake = FakeUninstaller()
        let state = UninstallerViewState(lister: fake, finder: finder, mover: fake)
        await state.appear()
        let task = Task { await state.select(Rig.photo.id) }
        await finder.gate.waitForCall()
        #expect(state.isLoadingDetails)
        state.review()
        #expect(!state.isReviewing)
        finder.gate.release(Rig.photoDetails)
        await task.value
    }

    @Test func nothingMovesWithoutReview() async {
        let rig = await selected()
        await rig.state.confirm()
        #expect(rig.fake.moves.isEmpty)
        #expect(rig.state.lastOutcome == nil)
    }

    @Test func confirmPassesExactlyTheTickedLeftoversAndIncludeApp() async {
        let rig = await selected()
        rig.state.toggleLeftover(Rig.photoCache.id)
        rig.state.toggleLeftover(Rig.photoAgent.id)
        rig.state.review()
        await rig.state.confirm()
        #expect(rig.fake.moves == [
            .init(
                appID: Rig.photo.id, appBytes: 500 * Rig.megabyte,
                leftoverIDs: [Rig.photoSupport.id, Rig.photoAgent.id], includeApp: true
            )
        ])
    }

    @Test func leftoversOnlyMoveWhenTheAppIsUnticked() async {
        let rig = await selected()
        rig.state.toggleApp()
        rig.state.review()
        await rig.state.confirm()
        #expect(rig.fake.moves.first?.includeApp == false)
        #expect(rig.state.apps.contains(Rig.photo))
        #expect(rig.state.details?.leftovers == [Rig.photoByName, Rig.photoAgent])
        #expect(rig.state.selectedID == Rig.photo.id)
    }

    @Test func movedAppLeavesTheListAndClearsTheSelection() async {
        let rig = await selected()
        rig.state.review()
        await rig.state.confirm()
        #expect(rig.state.apps == [Rig.notes])
        #expect(rig.state.selectedID == nil)
        #expect(rig.state.details == nil)
        #expect(!rig.state.isReviewing)
        #expect(!rig.state.isMoving)
        #expect(rig.state.resultText == "Moved 3 items, about \(formatBytes(1500 * Rig.megabyte)), to the Trash.")
    }

    @Test func failuresStayListedWithTheirReasons() async {
        let rig = await selected()
        rig.fake.configure { $0.failing[Rig.photoCache.id] = "It changed." }
        rig.state.toggleApp()
        rig.state.review()
        await rig.state.confirm()
        #expect(rig.state.details?.leftovers.contains(Rig.photoCache) == true)
        #expect(rig.state.failureReason(Rig.photoCache.id) == "It changed.")
        #expect(rig.state
            .resultText ==
            "Moved 1 item, about \(formatBytes(800 * Rig.megabyte)), to the Trash. 1 could not be moved.")
        #expect(rig.state.failureLines == ["com.example.photo: It changed."])
    }

    @Test func aMovedAppWithAFailedLeftoverReportsItInTheResult() async {
        let rig = await selected()
        rig.fake.configure { $0.failing[Rig.photoCache.id] = "It changed." }
        rig.state.review()
        await rig.state.confirm()
        #expect(rig.state.apps == [Rig.notes])
        #expect(rig.state.failureLines == ["com.example.photo: It changed."])
    }

    @Test func aRefusedAppIsNotMovedAndItsLeftoversAreSkipped() async {
        let rig = await selected()
        rig.fake.configure { $0.appRefusal = "It is open. Quit it first." }
        rig.state.review()
        await rig.state.confirm()
        #expect(rig.state.apps.contains(Rig.photo))
        #expect(rig.state.details == Rig.photoDetails)
        #expect(rig.state.resultText == "Nothing was moved.")
        let lines = rig.state.failureLines
        #expect(lines.first == "Photo Studio: not moved. It is open. Quit it first.")
        #expect(lines.count == 3)
        #expect(lines.dropFirst().allSatisfy { $0.hasSuffix("skipped because the app was not moved.") })
    }

    @Test func resultSaysAtLeastWhenSomethingMovedWasOnlyPartlyMeasured() async {
        let partial = Rig.leftover("com.example.photo", 10, .identifier, lowerBound: true)
        let details = AppDetails(app: Rig.photo, appBytes: 0, appIsLowerBound: false, leftovers: [partial])
        let rig = await selected(Rig(FakeUninstaller(details: [details])))
        rig.state.toggleApp()
        rig.state.review()
        await rig.state.confirm()
        #expect(rig.state.resultText == "Moved 1 item, at least \(formatBytes(10 * Rig.megabyte)), to the Trash.")
    }

    @Test func appearWhileMovingOrReviewingIsIgnored() async {
        let mover = GatedUninstaller()
        let fake = FakeUninstaller()
        let state = UninstallerViewState(lister: fake, finder: fake, mover: mover)
        await state.appear()
        await state.select(Rig.photo.id)
        state.review()
        await state.appear()
        #expect(fake.lists == 1)
        let task = Task { await state.confirm() }
        await mover.gate.waitForCall()
        #expect(state.isMoving)
        await state.appear()
        #expect(fake.lists == 1)
        mover.gate.release(UninstallOutcome(
            appMoved: false, appFailure: "x", appBytes: 0, movedLeftovers: [], failedLeftovers: [], skipped: []
        ))
        await task.value
    }

    @Test func selectAndTogglesAreIgnoredWhileMoving() async {
        let mover = GatedUninstaller()
        let fake = FakeUninstaller()
        let state = UninstallerViewState(lister: fake, finder: fake, mover: mover)
        await state.appear()
        await state.select(Rig.photo.id)
        state.review()
        let task = Task { await state.confirm() }
        await mover.gate.waitForCall()
        await state.select(Rig.notes.id)
        state.toggleApp()
        state.toggleLeftover(Rig.photoCache.id)
        #expect(state.selectedID == Rig.photo.id)
        #expect(state.includesApp)
        #expect(state.isSelected(leftover: Rig.photoCache.id))
        mover.gate.release(UninstallOutcome(
            appMoved: false, appFailure: "x", appBytes: 0, movedLeftovers: [], failedLeftovers: [], skipped: []
        ))
        await task.value
    }

    @Test func textNeverClaimsSafetyAndCleansNames() {
        let hostile = Rig.leftover("a\u{202E}b\nc", 1, .identifier)
        #expect(!UninstallerText.subtitle(hostile).contains("\u{202E}"))
        #expect(!UninstallerText.subtitle(hostile).contains("\n"))
        let all = [UninstallerText.reviewNote, UninstallerText.intro, UninstallerText.nameOnlyHeader,
                   UninstallerText.launchAgentWarning, UninstallerText.quitFirst]
        for text in all {
            #expect(!text.localizedCaseInsensitiveContains("safe"))
            #expect(!text.localizedCaseInsensitiveContains("all traces"))
        }
        #expect(UninstallerText.reviewNote
            .contains("These items move to the Trash. Space comes back when you empty the Trash."))
    }
}
