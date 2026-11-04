import Foundation
import MainternanceDomain
@testable import MainternancePresentation
import SwiftUI
import Testing

/// Exact label, symbol and rule mappings; a change to any of them is a visible change to the user.
@MainActor
struct MappingsTests {
    @Test func fileKindLabelsAndSymbols() {
        let expected: [SampleFileKind: (String, String)] = [
            .document: ("Documents", "doc.text"), .image: ("Images", "photo"), .video: ("Videos", "film"),
            .audio: ("Audio", "waveform"), .archive: ("Archives", "archivebox"),
            .code: ("Code", "chevron.left.forwardslash.chevron.right"), .other: ("Other", "doc")
        ]
        #expect(expected.count == SampleFileKind.allCases.count)
        for kind in SampleFileKind.allCases {
            #expect(kind.title == expected[kind]?.0)
            #expect(kind.symbol == expected[kind]?.1)
            #expect(kind.id == kind.rawValue)
        }
    }

    @Test func sizeAndDateFilters() {
        #expect(SizeFilter.allCases.map(\.title) == ["Any size", "Over 1 MB", "Over 100 MB", "Over 1 GB"])
        #expect(SizeFilter.allCases.map(\.minimumBytes) == [0, 1_000_000, 100_000_000, 1_000_000_000])
        #expect(SizeFilter.over1MB.id == "over1MB")
        #expect(DateFilter.allCases.map(\.title) == ["Any date", "Past day", "Past week", "Past month", "Past year"])
        #expect(DateFilter.allCases.map(\.days) == [nil, 1, 7, 30, 365])
        #expect(DateFilter.pastWeek.id == "pastWeek")
    }

    @Test func criteriaActivity() {
        var criteria = FileSearchCriteria()
        #expect(!criteria.isActive)
        criteria.text = "   "
        #expect(!criteria.isActive)
        criteria.text = "a"
        #expect(criteria.isActive)
        criteria = FileSearchCriteria(kind: .image)
        #expect(criteria.isActive)
    }

    @Test func keepRuleAndSegmentTitles() {
        #expect(KeepRule.allCases.map(\.title) == ["Newest", "Oldest", "Shortest path"])
        #expect(KeepRule.shortestPath.id == "shortestPath")
        #expect(FilesSegment.allCases.map(\.title) == ["Search", "Duplicates", "Large files"])
        #expect(FilesSegment.large.id == "large")
    }

    @Test func healthStyleColorsTitlesAndNotes() {
        #expect(HealthState.good.color == .green)
        #expect(HealthState.needsAttention.color == .orange)
        #expect(HealthState.problem.color == .red)
        #expect([HealthState.good, .needsAttention, .problem].map(\.title) == ["Good", "Needs attention", "Problem"])
    }

    @Test func sidebarCoversEveryDestinationInOrder() {
        let order = SidebarItem.all.map(\.destination)
        #expect(order == [.home, .cleanup, .files, .scanner, .startup, .uninstaller, .settings])
        for item in SidebarItem.all {
            #expect(SidebarItem.item(for: item.destination) == item)
            #expect(item.id == item.destination)
        }
    }

    @Test func navigationOpensAndIgnoresRepeats() {
        let navigation = Navigation()
        #expect(navigation.selection == .home)
        navigation.open(.settings)
        navigation.open(.settings)
        #expect(navigation.selection == .settings)
    }

    @Test func coordinatorCombinesSourcesBeforeTellingTheModel() async {
        let model = OverviewViewModel(
            load: LoadOverview(
                snapshots: FakeSnapshots(counter: CallCounter()), scans: FakeScans(), actions: FakeActions()
            ),
            sleep: { _ in }
        )
        let coordinator = VisibilityCoordinator(viewModel: model)
        coordinator.report(.popover, visible: true)
        coordinator.report(.window, visible: true)
        coordinator.report(.popover, visible: false) // the window still shows the model
        await model.refresh()
        #expect(model.history.count == 1)
        coordinator.report(.window, visible: false)
        await model.refresh()
        #expect(model.history.count == 1) // hidden: no new sample
    }

    @Test func homeCountsAsVisibleOnlyWhenTheWindowShowsHome() {
        var combiner = VisibilityCombiner()
        #expect(!combiner.isHomeVisible)
        combiner.update(.popover, visible: true)
        #expect(!combiner.isHomeVisible) // the popover has no suggestions
        combiner.update(.window, visible: true)
        #expect(combiner.isHomeVisible)
        combiner.select(.cleanup)
        #expect(!combiner.isHomeVisible)
        combiner.select(.home)
        combiner.update(.window, visible: false)
        #expect(!combiner.isHomeVisible)
    }

    @Test func coordinatorTellsWhenHomeShowsOrHides() {
        let model = OverviewViewModel(
            load: LoadOverview(
                snapshots: FakeSnapshots(counter: CallCounter()), scans: FakeScans(), actions: FakeActions()
            ),
            sleep: { _ in }
        )
        let seen = Recorded<Bool>()
        let coordinator = VisibilityCoordinator(viewModel: model, onHomeVisibilityChange: { seen.add($0) })
        coordinator.report(.window, visible: true)
        coordinator.report(.popover, visible: true) // unchanged for Home: not told again
        coordinator.select(.cleanup)
        coordinator.select(.settings)
        coordinator.select(.home)
        coordinator.report(.window, visible: false)
        #expect(seen.all == [true, false, true, false])
    }
}
