import Foundation
import MainternanceDomain
@testable import MainternancePresentation
import Testing

/// A detection is saved the moment it is reported, and a scan that never ends is remembered as unfinished.
@MainActor
struct ScannerIncrementalTests {
    private func startHeldScan(_ rig: ScannerRig, events: [ScanEvent]) -> Task<Void, Never> {
        rig.engine.configure {
            $0.holdScan = true
            $0.scanEvents = events
        }
        return Task { await rig.model.startScan(.quick) }
    }

    @Test func aFindingIsSavedAsSoonAsItIsReportedWhileTheScanIsStillRunning() async {
        let rig = await ScannerRig.ready()
        let scan = startHeldScan(rig, events: [.started(scope: .quick), .found(makeFinding(1))])
        #expect(await rig.model.wait { rig.model.findings == [makeFinding(1)] })
        #expect(await rig.model.wait { rig.model.run.isWorking })
        // Nothing has finished yet, and the detection is already on disk (a quit now would SIGKILL the scan).
        #expect(await rig.waitForMemory { $0.findings == [makeFinding(1)] })
        rig.engine.emit(.found(makeFinding(2)))
        #expect(await rig.waitForMemory { $0.findings == [makeFinding(1), makeFinding(2)] })
        rig.engine.emit(.finished(makeSummary(findings: 2)))
        rig.engine.finishScan()
        await scan.value
    }

    @Test func aStartedScanIsRememberedAsNotFinishedUntilItEnds() async {
        let rig = await ScannerRig.ready()
        let scan = startHeldScan(rig, events: [.started(scope: .quick)])
        #expect(await rig.waitForMemory { $0.scanDidNotFinish })
        #expect(rig.model.scanDidNotFinish)
        rig.engine.emit(.finished(makeSummary()))
        rig.engine.finishScan()
        await scan.value
        #expect(!rig.model.scanDidNotFinish)
        #expect(rig.store.lastMemory?.scanDidNotFinish == false)
    }

    @Test func aCancelledScanRecordsItsOwnStateAndClearsTheFlag() async {
        let rig = await ScannerRig.ready()
        rig.engine.configure { $0.cancelSummary = makeSummary(cancelled: true) }
        let scan = startHeldScan(rig, events: [.started(scope: .quick)])
        #expect(await rig.waitForMemory { $0.scanDidNotFinish })
        await rig.model.cancel()
        await scan.value
        #expect(rig.store.lastMemory?.scanDidNotFinish == false)
    }

    @Test func aFailedScanRecordsItsOwnStateAndClearsTheFlag() async {
        let rig = await ScannerRig.ready()
        rig.engine.configure { $0.scanEvents = [.started(scope: .quick), .failed(message: "stopped")] }
        await rig.model.startScan(.quick)
        #expect(rig.store.lastMemory?.scanDidNotFinish == false)
        #expect(!rig.model.scanDidNotFinish)
    }

    @Test func aScanRefusedBeforeItStartedNeverSetsTheFlag() async {
        let rig = await ScannerRig.ready()
        rig.engine.configure { $0.scanEvents = [.failed(message: "not ready")] }
        await rig.model.startScan(.quick)
        #expect(rig.store.memories.allSatisfy { !$0.scanDidNotFinish })
        #expect(!rig.model.scanDidNotFinish)
    }

    @Test func theFlagComesBackAfterARestartAndIsShownOnTheScreen() async {
        let rig = ScannerRig()
        rig.store.state.withLock {
            $0.stored = RecordedScanStatus(summary: nil, findings: [makeFinding(1)], scanDidNotFinish: true)
        }
        await rig.model.refreshStatus()
        #expect(rig.model.scanDidNotFinish)
        #expect(rig.model.findings == [makeFinding(1)])
        #expect(ScannerText.lastScanDidNotFinish == [
            "The last scan did not finish (the app was closed or stopped during it), so its results are incomplete.",
            "Run a scan again."
        ].joined(separator: " "))
    }

    @Test func savedStatusIsLoadedEvenWhenSomethingIsAlreadyRunning() async {
        let rig = ScannerRig()
        rig.store.state.withLock { $0.stored = RecordedScanStatus(summary: nil, findings: [makeFinding(1)]) }
        let running = ScannerViewModel.RunState.scanning(scanned: 3, current: "/x")
        rig.model.run = running
        await rig.model.refreshStatus()
        #expect(rig.model.findings == [makeFinding(1)])
        #expect(rig.model.run == running)
    }

    @Test func aLoadThatCameBackEmptyIsNotRetriedForever() async {
        let rig = ScannerRig()
        await rig.model.refreshStatus()
        rig.store.state.withLock { $0.stored = RecordedScanStatus(summary: nil, findings: [makeFinding(1)]) }
        await rig.model.refreshStatus()
        #expect(rig.model.findings.isEmpty)
    }
}

extension ScannerRig {
    /// Waits (without polling) until a memory written to the store satisfies `predicate`; false after 10 s.
    func waitForMemory(_ predicate: @escaping @Sendable (ScanMemory) -> Bool) async -> Bool {
        let store = store
        if store.memories.contains(where: predicate) {
            return true
        }
        let watcher = Task {
            for await _ in store.writes where store.memories.contains(where: predicate) {
                return true
            }
            return false
        }
        let timeout = Task {
            try? await Task.sleep(for: .seconds(10))
            watcher.cancel()
        }
        let result = await watcher.value
        timeout.cancel()
        return result
    }
}

@MainActor
struct ScannerManyDetectionsTests {
    @Test func thousandsOfDetectionsUseTheCoalescedSaveAndEndWithOneCompleteWrite() async {
        let rig = await ScannerRig.ready()
        let many = (1 ... 5000).map { makeFinding($0, path: "/Users/someone/Downloads/many/file\($0).bin") }
        rig.engine.configure {
            $0.scanEvents = [.started(scope: .quick)] + many.map { .found($0) }
                + [.finished(makeSummary(findings: many.count))]
        }
        await rig.model.startScan(.quick)
        #expect(rig.model.findings.count == 5000)
        let progress = rig.store.state.withLock { $0.progress }
        #expect(progress.count == 5000) // every detection is handed over at once, the store coalesces the writes
        #expect(progress.last?.findings.count == 5000)
        // Only the start, and the end of the scan, are immediate writes.
        #expect(rig.store.remembered.count == 1)
        #expect(rig.store.recorded.count == 1)
        #expect(rig.store.lastMemory?.findings.count == 5000)
    }
}

@MainActor
struct ScannerUnreadableResultsTests {
    @Test func anUnreadableSavedFileIsSaidOutLoudAndNeverTurnsIntoNothingToReport() async {
        let rig = ScannerRig()
        rig.store.state.withLock { $0.unreadable = true }
        await rig.model.refreshStatus()
        #expect(rig.model.savedResultsUnreadable)
        #expect(rig.model.findings.isEmpty)
        #expect(ScannerText.savedResultsUnreadable == "The scanner's saved results could not be read.")
    }

    @Test func aFileThatWasMovedAsideEarlierIsRememberedAsUnreadableToo() async {
        let rig = ScannerRig()
        rig.store.state.withLock {
            $0.stored = RecordedScanStatus(summary: nil, findings: [], earlierResultsUnreadable: true)
        }
        await rig.model.refreshStatus()
        #expect(rig.model.savedResultsUnreadable)
    }

    @Test func aCompletedScanClearsTheNotice() async {
        let rig = ScannerRig()
        rig.store.state.withLock { $0.unreadable = true }
        await rig.model.refreshStatus()
        await rig.scanFinding([], scope: .quick)
        #expect(!rig.model.savedResultsUnreadable)
    }

    @Test func aCancelledScanDoesNotClearIt() async {
        let rig = ScannerRig()
        rig.store.state.withLock { $0.unreadable = true }
        await rig.model.refreshStatus()
        rig.engine.configure { $0.scanEvents = [.started(scope: .quick), .finished(makeSummary(cancelled: true))] }
        await rig.model.startScan(.quick)
        #expect(rig.model.savedResultsUnreadable)
    }

    @Test func aFileThatIsMissingIsNotUnreadable() async {
        let rig = ScannerRig()
        await rig.model.refreshStatus()
        #expect(!rig.model.savedResultsUnreadable)
    }
}
