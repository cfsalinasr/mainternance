import Foundation
import MainternanceDomain
@testable import MainternancePresentation
import Testing

/// Rules that used to sit in views and now live in testable state types.
@MainActor
struct ViewLogicTests {
    private let utc = TimeZone(identifier: "UTC") ?? .gmt

    @Test func scannerScheduleFollowsSettingsChanges() {
        let states = WindowStates()
        let british = Locale(identifier: "en_GB")
        #expect(states.scanner.scheduleSummary(locale: british, timeZone: utc) == "Weekly, Sunday 02:00")
        states.settings.setWeekday(3)
        states.settings.setTime(hour: 18, minute: 30)
        #expect(states.scanner.scheduleSummary(locale: british, timeZone: utc) == "Weekly, Tuesday 18:30")
        #expect(states.settings.scheduleSummary(locale: british, timeZone: utc) == "Weekly, Tuesday 18:30")
    }

    @Test func resultsContentFollowsTheRun() {
        let state = ScannerViewState()
        let expected: [(String, ScannerViewState.ResultsContent)] = [
            ("ready-idle", .none), ("ready-running", .none), ("ready-findings", .findings), ("ready-clean", .clean)
        ]
        for (id, content) in expected {
            state.select(previewID: id)
            #expect(state.resultsContent == content)
        }
    }

    @Test func drillableChildrenExcludeLeavesAndEmptyFolders() {
        let tree = TreemapNode(id: "root", name: "Root", leafSize: 0, children: [
            TreemapNode(id: "folder", name: "Folder", leafSize: 0, children: [
                TreemapNode(id: "inner", name: "Inner", leafSize: 10)
            ]),
            TreemapNode(id: "zero-folder", name: "Zero", leafSize: 0, children: [
                TreemapNode(id: "empty", name: "Empty", leafSize: 0)
            ]),
            TreemapNode(id: "leaf", name: "Leaf", leafSize: 50)
        ])
        let state = FilesViewState(treemap: tree)
        #expect(state.drillableChildren.map(\.id) == ["folder"])
        state.drillInto("zero-folder") // size 0: not drillable, same rule as the buttons
        state.drillInto("leaf")
        #expect(state.currentNode.id == "root")
        state.drillInto("folder")
        #expect(state.currentNode.id == "folder")
    }

    @Test func largestFilesAreSortedOnceByTheState() {
        let stamp = Date(timeIntervalSince1970: 0)
        let files = [10, 300, 20].map {
            SampleFile(name: "f\($0)", path: "/f\($0)", size: Int64($0), modified: stamp, kind: .other)
        }
        let state = FilesViewState(largest: files)
        #expect(state.largest.map(\.size) == [300, 20, 10])
    }

    @Test func weekdayOptionsCoverOneToSevenWithNames() {
        let options = SettingsViewState().weekdayOptions(locale: Locale(identifier: "en_US"))
        #expect(options.map(\.value) == Array(1 ... 7))
        #expect(options.first?.name == "Sunday")
        #expect(options.last?.name == "Saturday")
        #expect(options.allSatisfy { !$0.name.isEmpty })
    }

    @Test func weekdayNameIsEmptyOutOfRange() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US")
        #expect(ScanSchedule.weekdayName(0, calendar: calendar).isEmpty)
        #expect(ScanSchedule.weekdayName(8, calendar: calendar).isEmpty)
        #expect(ScanSchedule.weekdayName(2, calendar: calendar) == "Monday")
    }

    @Test func leftoverDisplayNameIsTheLastPathComponent() {
        func name(_ path: String) -> String {
            Leftover(id: path, path: path, bytes: 0).displayName
        }
        #expect(name("~/Library/Logs/VideoEditor") == "VideoEditor")
        #expect(name("~/Library/Logs/VideoEditor/") == "VideoEditor")
        #expect(name("~/") == "~")
        #expect(name("/") == "/")
        #expect(name("").isEmpty)
    }
}

@MainActor
struct ScanGatingTests {
    @Test func scansNeverStartWhileTheEngineIsNotConnected() {
        let state = ScannerViewState()
        #expect(!state.engineConnected)
        for preview in ScannerPreview.all {
            state.select(previewID: preview.id)
            #expect(!state.canStartScan, "\(preview.id)")
        }
        // The sample "ready" engine can scan on its own; only the missing connection disables the buttons.
        state.select(previewID: "ready-idle")
        #expect(state.engine.canScan)
    }

    @Test func scansStartOnlyWhenTheEngineCanScanAndIsConnected() {
        for connected in [false, true] {
            let state = ScannerViewState(engineConnected: connected)
            for preview in ScannerPreview.all {
                state.select(previewID: preview.id)
                #expect(state.canStartScan == (preview.engine.canScan && connected), "\(preview.id) \(connected)")
            }
        }
    }

    @Test func sampleNoteAndHelpTextAreExact() {
        #expect(ScannerViewState.sampleNote == "Sample only: no scans run yet")
        #expect(ScannerHelp.engineNotConnected == "Available when the scanner engine is connected")
    }

    @Test func scheduleIsLabelledAsASample() {
        let states = WindowStates()
        states.settings.setWeekday(2)
        states.settings.setTime(hour: 9, minute: 5)
        let british = Locale(identifier: "en_GB")
        let utc = TimeZone(identifier: "UTC") ?? .gmt
        let summary = states.settings.scheduleSummary(locale: british, timeZone: utc)
        #expect(summary == "Weekly, Monday 09:05") // the displayed text is unchanged
        #expect(states.settings
            .scheduleAccessibilityLabel(locale: british, timeZone: utc) == "Sample schedule: \(summary)")
        #expect(states.scanner
            .scheduleAccessibilityLabel(locale: british, timeZone: utc) == "Sample schedule: \(summary)")
        #expect(ScanScheduleStore.previewCaption == "Preview: nothing is scheduled yet")
    }
}
