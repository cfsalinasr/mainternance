import Foundation
@testable import MainternancePresentation
import Testing

@MainActor
struct ScannerStateTests {
    @Test func engineTitles() {
        #expect(ScannerEngineState.notInstalled.title == "Scanning engine not installed")
        #expect(ScannerEngineState.installing(progress: 0.2).title == "Installing…")
        #expect(ScannerEngineState.downloadingDefinitions(progress: 0.2).title == "Downloading definitions…")
        #expect(ScannerEngineState.ready(definitionsAge: .seconds(60)).title == "Engine ready")
        #expect(ScannerEngineState.updateNeeded.title == "Definitions out of date")
    }

    @Test func scanButtonsEnabledOnlyWhenReady() {
        #expect(ScannerEngineState.ready(definitionsAge: .seconds(0)).canScan)
        #expect(!ScannerEngineState.notInstalled.canScan)
        #expect(!ScannerEngineState.installing(progress: 1).canScan)
        #expect(!ScannerEngineState.downloadingDefinitions(progress: 1).canScan)
        #expect(!ScannerEngineState.updateNeeded.canScan)
    }

    @Test func progressIsClamped() {
        #expect(ScannerProgress.clamp(-0.5) == 0)
        #expect(ScannerProgress.clamp(1.7) == 1)
        #expect(ScannerProgress.clamp(0.25) == 0.25)
        #expect(ScannerProgress.clamp(.nan) == 0)
        #expect(ScannerEngineState.installing(progress: 9).progress == 1)
        #expect(ScannerEngineState.notInstalled.progress == nil)
    }

    @Test func runTitles() {
        #expect(ScanRunState.finished(findings: 0).title == "No threats found")
        #expect(ScanRunState.running(scanned: 5, current: "/").title == "Scanning…")
    }

    @Test func scheduleFollowsLocaleClock() throws {
        let utc = try #require(TimeZone(identifier: "UTC"))
        let schedule = ScanSchedule()
        #expect(schedule.description(locale: Locale(identifier: "en_GB"), timeZone: utc) == "Weekly, Sunday 02:00")
        #expect(schedule.description(locale: Locale(identifier: "en_US"), timeZone: utc).contains("2:00"))
        #expect(ScanSchedule(weekday: 99).description(locale: Locale(identifier: "en_GB"), timeZone: utc)
            .hasPrefix("Weekly,"))
    }

    @Test func selectingPreviewChangesStates() {
        let state = ScannerViewState()
        state.select(previewID: "not-installed")
        #expect(state.engine == .notInstalled)
        state.select(previewID: "ready-clean")
        #expect(state.run == .finished(findings: 0))
        state.select(previewID: "bogus")
        #expect(state.previewID == "ready-clean")
    }

    @Test func everyPreviewIsReachable() {
        let state = ScannerViewState()
        for preview in ScannerPreview.all {
            state.select(previewID: preview.id)
            #expect(state.engine == preview.engine)
            #expect(state.run == preview.run)
        }
        #expect(Set(ScannerPreview.all.map(\.id)).count == ScannerPreview.all.count)
    }

    @Test func quarantineNeedsConfirmationThenRestores() throws {
        let state = ScannerViewState()
        let id = try #require(state.findings.first).id
        state.requestQuarantine(id)
        #expect(state.pendingFinding?.id == id)
        #expect(!state.isQuarantined(id))
        state.cancelQuarantine()
        #expect(state.pendingFinding == nil)
        #expect(!state.isQuarantined(id))
        state.requestQuarantine(id)
        state.confirmQuarantine()
        #expect(state.isQuarantined(id))
        #expect(state.pendingFinding == nil)
        state.restore(id)
        #expect(!state.isQuarantined(id))
    }

    @Test func unknownIdIsNoOp() {
        let state = ScannerViewState()
        state.quarantine("nope")
        state.requestQuarantine("nope")
        state.restore("nope")
        #expect(state.quarantined.isEmpty)
        #expect(state.pendingQuarantineID == nil)
    }

    @Test func sampleFindingsInvariants() {
        let findings = ScannerSampleData.findings
        #expect(findings.count == 3)
        #expect(findings.allSatisfy { !$0.id.isEmpty && !$0.reason.isEmpty && !$0.path.isEmpty })
        #expect(Set(findings.map(\.id)).count == findings.count)
    }
}
