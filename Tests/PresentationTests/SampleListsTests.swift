import Foundation
@testable import MainternancePresentation
import Testing

@MainActor
struct SampleListsTests {
    @Test func cleanupTotalIsSumOfCategoriesAndMatchesHome12GB() {
        let categories = SampleLists.cleanupCategories
        #expect(categories.count == 5)
        #expect(SampleLists.cleanupTotalBytes == categories.map(\.bytes).reduce(0, +))
        // The Home suggested action reads "Clear 12 GB of junk"; the sample total rounds to 12 GB.
        let gigabytes = (SampleLists.cleanupTotalBytes + 500_000_000) / 1_000_000_000
        #expect(gigabytes == 12)
        #expect(formatBytes(SampleLists.cleanupTotalBytes) == "12 GB")
    }

    @Test func everyAppHasLeftoversAndTotalIsTheirSum() {
        #expect(!SampleLists.apps.isEmpty)
        for app in SampleLists.apps {
            #expect(!app.leftovers.isEmpty)
            #expect(app.totalBytes == app.leftovers.map(\.bytes).reduce(0, +))
        }
    }

    @Test func sumIgnoresNegatives() {
        #expect(SampleLists.sum([5, -3, 2]) == 7)
        #expect(SampleLists.sum([]) == 0)
    }

    @Test func sharedByteFormatterCoversUnitsAndZero() {
        #expect(formatBytes(41_000_000_000) == "41 GB")
        #expect(formatBytes(240_000_000) == "240 MB")
        #expect(formatBytes(12000) == "12 KB")
        #expect(formatBytes(0).contains("0"))
        #expect(!formatBytes(0).localizedCaseInsensitiveContains("zero"))
        #expect(formatBytes(-5) == formatBytes(0))
    }
}

@MainActor
struct CleanupViewStateTests {
    @Test func startsWithEverythingSelected() {
        let state = CleanupViewState()
        #expect(state.selectedBytes == SampleLists.cleanupTotalBytes)
        #expect(state.canReview)
    }

    @Test func toggleChangesTotal() throws {
        let state = CleanupViewState()
        let first = try #require(state.categories.first)
        state.toggle(first.id)
        #expect(!state.isSelected(first.id))
        #expect(state.selectedBytes == SampleLists.cleanupTotalBytes - first.bytes)
        state.toggle(first.id)
        #expect(state.selectedBytes == SampleLists.cleanupTotalBytes)
    }

    @Test func emptySelectionIsZeroAndCannotReview() {
        let state = CleanupViewState()
        for category in state.categories {
            state.toggle(category.id)
        }
        #expect(state.selectedBytes == 0)
        #expect(!state.canReview)
        state.review()
        #expect(!state.isReviewing)
    }

    @Test func toggleUnknownIdIsNoOp() {
        let state = CleanupViewState()
        state.toggle("nope")
        #expect(state.selected.count == state.categories.count)
    }

    @Test func confirmWithoutReviewDoesNothing() {
        let state = CleanupViewState()
        state.confirmReview()
        #expect(state.cleaned.isEmpty)
        #expect(state.selectedBytes == SampleLists.cleanupTotalBytes)
    }

    @Test func cancelKeepsSelectionAndCloses() {
        let state = CleanupViewState()
        state.review()
        #expect(state.isReviewing)
        state.cancelReview()
        #expect(!state.isReviewing)
        #expect(state.cleaned.isEmpty)
        #expect(state.selectedBytes == SampleLists.cleanupTotalBytes)
    }

    @Test func confirmMarksCleanedAndIsIdempotent() {
        let state = CleanupViewState()
        state.review()
        state.confirmReview()
        #expect(state.cleaned.count == state.categories.count)
        #expect(state.cleanedBytes == SampleLists.cleanupTotalBytes)
        #expect(state.selectedBytes == 0)
        #expect(!state.isReviewing)
        #expect(!state.canReview)
        state.review() // Nothing left to review.
        state.confirmReview()
        #expect(state.cleanedBytes == SampleLists.cleanupTotalBytes)
        #expect(!state.isReviewing)
    }

    @Test func cleanedCategoryCannotBeToggledBack() throws {
        let state = CleanupViewState()
        let first = try #require(state.categories.first)
        state.review()
        state.confirmReview()
        state.toggle(first.id)
        #expect(!state.isSelected(first.id))
        #expect(state.isCleaned(first.id))
    }

    @Test func toggleDuringReviewIsIgnored() throws {
        let state = CleanupViewState()
        let first = try #require(state.categories.first)
        state.review()
        state.toggle(first.id)
        #expect(state.isSelected(first.id))
    }

    @Test func partialConfirmCleansOnlySelected() throws {
        let state = CleanupViewState()
        let first = try #require(state.categories.first)
        state.toggle(first.id)
        state.review()
        #expect(state.reviewItems.count == state.categories.count - 1)
        state.confirmReview()
        #expect(!state.isCleaned(first.id))
        #expect(state.cleanedBytes == SampleLists.cleanupTotalBytes - first.bytes)
    }
}

@MainActor
struct UninstallerViewStateTests {
    @Test func selectsKnownApp() throws {
        let state = UninstallerViewState()
        let last = try #require(state.apps.last)
        state.select(last.id)
        #expect(state.selectedApp == last)
    }

    @Test func unknownIdClearsSelection() {
        let state = UninstallerViewState()
        #expect(state.selectedApp != nil) // Precondition: something is selected.
        state.select("nope")
        #expect(state.selectedID == nil)
        #expect(state.selectedApp == nil)
    }

    @Test func nilClearsSelection() {
        let state = UninstallerViewState()
        state.select(nil)
        #expect(state.selectedApp == nil)
    }

    @Test func emptyAppsIsSafe() {
        let state = UninstallerViewState(apps: [])
        #expect(state.selectedApp == nil)
    }
}

@MainActor
struct WindowStatesTests {
    @Test func constructsAllStates() {
        let states = WindowStates(
            scanner: ScannerRig().model, settings: SettingsRig().state, startup: StartupRig().state
        )
        #expect(!states.files.files.isEmpty)
        #expect(states.scanner.findings.isEmpty) // The real Scanner starts with nothing listed, never sample data.
        #expect(!states.cleanup.categories.isEmpty)
        #expect(states.startup.snapshot == nil) // the real Startup screen lists nothing until it has read the Mac
        #expect(!states.uninstaller.apps.isEmpty)
        #expect(states.settings.current == .defaults)
    }
}
