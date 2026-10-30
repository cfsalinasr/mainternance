import Foundation
import MainternanceDomain
@testable import MainternancePresentation
import SwiftUI
import Testing

/// Exact label, symbol and rule mappings; a change to any of them is a visible change to the user.
@MainActor
struct MappingsTests {
    @Test func fileKindLabelsAndSymbols() {
        let expected: [FileKind: (String, String)] = [
            .document: ("Documents", "doc.text"), .image: ("Images", "photo"), .video: ("Videos", "film"),
            .audio: ("Audio", "waveform"), .archive: ("Archives", "archivebox"),
            .code: ("Code", "chevron.left.forwardslash.chevron.right"), .other: ("Other", "doc")
        ]
        #expect(expected.count == FileKind.allCases.count)
        for kind in FileKind.allCases {
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

    @Test func scannerEngineTexts() {
        let ready = ScannerEngineState.ready(definitionsAge: .seconds(2 * 86400))
        #expect(ready.detail == "Definitions updated \(ScannerEngineState.ageText(.seconds(2 * 86400))) ago.")
        #expect(ScannerEngineState.ageText(.seconds(60)) == "less than an hour")
        #expect(ScannerEngineState.ageText(.seconds(-5)) == "less than an hour")
        #expect(ScannerEngineState.notInstalled.detail.contains("ClamAV"))
        #expect(ScannerEngineState.installing(progress: 0.1).detail == "Setting up the scanning engine.")
        #expect(ScannerEngineState.downloadingDefinitions(progress: 0.1).detail.contains("definitions"))
        #expect(ScannerEngineState.updateNeeded.detail.contains("Update"))
        #expect(ScannerEngineState.notInstalled.symbol == "shield.slash")
        #expect(ScannerEngineState.installing(progress: 0).symbol == "arrow.down.circle")
        #expect(ScannerEngineState.downloadingDefinitions(progress: 0).symbol == "arrow.down.circle")
        #expect(ready.symbol == "checkmark.shield")
        #expect(ScannerEngineState.updateNeeded.symbol == "exclamationmark.triangle")
    }

    @Test func scanRunTextsAndSeverities() {
        #expect(ScanRunState.idle.title == "No scan running")
        #expect(ScanRunState.idle.detail == "Start a quick or full scan.")
        #expect(ScanRunState.running(scanned: -4, current: "/").detail.hasPrefix("0 "))
        #expect(ScanRunState.finished(findings: 0).detail == "Your Mac looks clean.")
        #expect(ScanRunState.finished(findings: 1).detail == "1 item need your attention.")
        #expect(ScanRunState.finished(findings: 3).detail == "3 items need your attention.")
        #expect(ScanRunState.finished(findings: 3).title == "Scan finished")
        #expect([FindingSeverity.low, .medium, .high].map(\.title) == ["Low", "Medium", "High"])
        #expect([FindingSeverity.low, .medium, .high].map(\.symbol)
            == ["info.circle", "exclamationmark.triangle", "exclamationmark.octagon"])
    }

    @Test func startupKindTitles() {
        #expect(StartupKind.allCases.map(\.title) == ["Login items", "Launch agents", "Launch daemons"])
        #expect(StartupKind.loginItem.id == .loginItem)
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
}
