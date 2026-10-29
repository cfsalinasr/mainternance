import Foundation
@testable import MainternancePresentation
import Testing

@MainActor
struct SampleListsTests {
    @Test func cleanupTotalIsSumOfCategoriesAndMatchesHome12GB() {
        let categories = SampleLists.cleanupCategories
        #expect(categories.count == 5)
        #expect(SampleLists.cleanupTotalBytes == categories.map(\.bytes).reduce(0, +))
        let gigabytes = (Double(SampleLists.cleanupTotalBytes) / 1_000_000_000).rounded()
        #expect(gigabytes == 12) // The Home suggested action reads "Clear 12 GB of junk".
        #expect(formatFreeSpace(SampleLists.cleanupTotalBytes) == "12 GB")
    }

    @Test func startupSampleHasExactlyThreeNewItems() {
        #expect(SampleLists.startupItems.count { $0.isNew } == 3)
        for kind in StartupKind.allCases {
            #expect(SampleLists.startupItems.contains { $0.kind == kind })
        }
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

    @Test func byteTextIsLocaleAwareAndSafe() {
        #expect(formatBytes(-5, locale: Locale(identifier: "en_US")) == formatBytes(
            0,
            locale: Locale(identifier: "en_US")
        ))
        #expect(formatBytes(1_500_000, locale: Locale(identifier: "en_US")).contains("MB"))
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
struct StartupViewStateTests {
    @Test func toggleFlipsAndRestores() throws {
        let state = StartupViewState()
        let item = try #require(state.items.first)
        state.toggle(item.id)
        #expect(state.items.first { $0.id == item.id }?.isEnabled == !item.isEnabled)
        state.toggle(item.id)
        #expect(state.items.first { $0.id == item.id }?.isEnabled == item.isEnabled)
    }

    @Test func toggleUnknownIsNoOp() {
        let state = StartupViewState()
        let before = state.items
        state.toggle("nope")
        #expect(state.items == before)
    }

    @Test func groupsByKindAndCountsNew() {
        let state = StartupViewState()
        #expect(StartupKind.allCases.map { state.items(of: $0).count }.reduce(0, +) == state.items.count)
        #expect(state.newCount == 3)
    }

    @Test func emptyListIsSafe() {
        let state = StartupViewState(items: [])
        #expect(state.newCount == 0)
        #expect(state.items(of: .loginItem).isEmpty)
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
struct SettingsViewStateTests {
    @Test func scheduleInputsClamp() {
        #expect(ScheduleInput.weekday(0) == 1)
        #expect(ScheduleInput.weekday(8) == 7)
        #expect(ScheduleInput.weekday(4) == 4)
        #expect(ScheduleInput.hour(-1) == 0)
        #expect(ScheduleInput.hour(24) == 23)
        #expect(ScheduleInput.minute(-5) == 0)
        #expect(ScheduleInput.minute(60) == 59)
        #expect(ScheduleInput.minute(30) == 30)
    }

    @Test func settersClamp() {
        let state = SettingsViewState()
        state.setWeekday(99)
        state.setTime(hour: -3, minute: 75)
        #expect(state.weekday == 7)
        #expect(state.hour == 0)
        #expect(state.minute == 59)
    }

    @Test func timeFromDateRoundTrips() {
        let state = SettingsViewState()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        let date = calendar.date(from: DateComponents(year: 2026, month: 1, day: 5, hour: 17, minute: 45)) ?? Date()
        state.setTime(from: date, calendar: calendar)
        #expect(state.hour == 17)
        #expect(state.minute == 45)
        let back = calendar.dateComponents([.hour, .minute], from: state.timeDate(calendar: calendar))
        #expect(back.hour == 17 && back.minute == 45)
    }

    @Test func summaryFollowsLocale() throws {
        let utc = try #require(TimeZone(identifier: "UTC"))
        let state = SettingsViewState()
        state.setWeekday(2)
        state.setTime(hour: 14, minute: 5)
        #expect(state.scheduleSummary(locale: Locale(identifier: "en_GB"), timeZone: utc) == "Weekly, Monday 14:05")
        let usSummary = state.scheduleSummary(locale: Locale(identifier: "en_US"), timeZone: utc)
        #expect(usSummary.hasPrefix("Weekly, Monday 2:05"))
        #expect(usSummary.contains("PM"))
    }

    @Test func defaults() {
        let state = SettingsViewState()
        #expect(!state.launchAtLogin)
        #expect(state.problemAlerts)
        #expect(state.weeklyDigest)
    }
}

@MainActor
struct WindowStatesTests {
    @Test func constructsAllStates() {
        let states = WindowStates()
        #expect(!states.files.files.isEmpty)
        #expect(!states.scanner.findings.isEmpty)
        #expect(!states.cleanup.categories.isEmpty)
        #expect(!states.startup.items.isEmpty)
        #expect(!states.uninstaller.apps.isEmpty)
        #expect(states.settings.weekday == 1)
    }
}
