import Foundation
import MainternanceDomain
@testable import MainternancePresentation
import Testing

@MainActor
struct ScannerScanTests {
    // MARK: Scanning

    @Test func aScanStreamsProgressAndEndsFinished() async {
        let rig = await ScannerRig.ready()
        let summary = makeSummary(scanned: 42)
        rig.engine.configure {
            $0.holdScan = true
            $0.scanEvents = [.started(scope: .quick), .progress(scanned: 17, current: "/Users/someone/Downloads")]
        }
        let scan = Task { await rig.model.startScan(.quick) }
        let sawProgress = await rig.model.wait {
            rig.model.run == .scanning(scanned: 17, current: "/Users/someone/Downloads")
        }
        #expect(sawProgress)
        #expect(!rig.model.canStartScan)
        rig.engine.emit(.finished(summary))
        rig.engine.finishScan()
        await scan.value
        #expect(rig.model.run == .finished(summary))
        #expect(rig.model.canStartScan)
        #expect(rig.model.errorMessage == nil)
        #expect(rig.store.recorded.count == 1)
        #expect(rig.store.recorded.first?.summary == summary)
    }

    @Test func findingsAccumulateAndAreRecordedAsUnresolved() async {
        let rig = await ScannerRig.ready()
        await rig.scanFinding([makeFinding(1), makeFinding(2)])
        #expect(rig.model.findings == [makeFinding(1), makeFinding(2)])
        #expect(rig.store.recorded.first?.findings == [makeFinding(1), makeFinding(2)])
    }

    @Test func aSecondScanWhileOneRunsIsRejected() async {
        let rig = await ScannerRig.ready()
        rig.engine.configure { $0.holdScan = true; $0.scanEvents = [.started(scope: .quick)] }
        let first = Task { await rig.model.startScan(.quick) }
        var calls = rig.engine.scanCalls.makeAsyncIterator()
        _ = await calls.next()
        #expect(rig.model.run.isWorking)
        await rig.model.startScan(.full)
        #expect(rig.engine.scans == [.quick])
        rig.engine.finishScan()
        await first.value
    }

    @Test func cancelEndsTheScanCancelledAndKeepsWhatWasFound() async {
        let rig = await ScannerRig.ready()
        let cancelled = makeSummary(scanned: 7, cancelled: true)
        rig.engine.configure {
            $0.holdScan = true
            $0.cancelSummary = cancelled
            $0.scanEvents = [.started(scope: .full), .found(makeFinding(1))]
        }
        let scan = Task { await rig.model.startScan(.full) }
        var calls = rig.engine.scanCalls.makeAsyncIterator()
        _ = await calls.next()
        #expect(rig.model.canCancel)
        await rig.model.cancel()
        await scan.value
        #expect(rig.engine.state.withLock { $0.cancelCalls } == 1)
        #expect(rig.model.run == .finished(cancelled))
        #expect(rig.model.findings == [makeFinding(1)])
        #expect(rig.store.recorded.first?.summary.cancelled == true)
        #expect(rig.store.recorded.first?.findings == [makeFinding(1)])
        #expect(!rig.model.canCancel)
    }

    @Test func cancelDoesNothingWhenNoScanRuns() async {
        let rig = await ScannerRig.ready()
        await rig.model.cancel()
        #expect(rig.engine.state.withLock { $0.cancelCalls } == 0)
    }

    @Test func aFailedScanKeepsTheFindingsItAlreadyReportedAndShowsTheError() async {
        let rig = await ScannerRig.ready()
        rig.engine.configure {
            $0.scanEvents = [
                .started(scope: .quick), .found(makeFinding(1)), .found(makeFinding(2)),
                .failed(message: "clamscan stopped (exit 2); 1 detection could not be attributed")
            ]
        }
        await rig.model.startScan(.quick)
        #expect(rig.model.findings == [makeFinding(1), makeFinding(2)])
        #expect(rig.model.errorMessage == "clamscan stopped (exit 2); 1 detection could not be attributed")
        #expect(rig.model.run == .idle)
        #expect(rig.store.updates.last == [makeFinding(1), makeFinding(2)])
        #expect(rig.store.recorded.isEmpty)
    }

    @Test func aFailedScanNeverDropsOlderFindingsItDidNotRecheck() async {
        let rig = await ScannerRig.ready()
        await rig.scanFinding([makeFinding(1), makeFinding(2)])
        rig.engine.configure {
            $0.scanEvents = [.started(scope: .full), .found(makeFinding(2)), .failed(message: "clamscan stopped")]
        }
        await rig.model.startScan(.full)
        #expect(Set(rig.model.findings.map(\.id)) == [makeFinding(1).id, makeFinding(2).id])
        #expect(rig.model.findings.count == 2)
        #expect(rig.model.errorMessage == "clamscan stopped")
    }

    @Test func aCompletedScanReplacesOlderFindings() async {
        let rig = await ScannerRig.ready()
        await rig.scanFinding([makeFinding(1), makeFinding(2)])
        await rig.scanFinding([makeFinding(3)])
        #expect(rig.model.findings == [makeFinding(3)])
    }

    @Test func aScanRefusedBeforeItStartedChangesNothing() async {
        let rig = await ScannerRig.ready()
        await rig.scanFinding([makeFinding(1)])
        rig.engine
            .configure { $0.scanEvents = [.failed(message: "Scanning engine is not ready: ClamAV is not installed")] }
        await rig.model.startScan(.quick)
        #expect(rig.model.findings == [makeFinding(1)])
        #expect(rig.model.errorMessage == "Scanning engine is not ready: ClamAV is not installed")
        #expect(rig.store.updates.isEmpty)
    }

    @Test func aScanThatEndsWithoutAnyResultSaysSo() async {
        let rig = await ScannerRig.ready()
        rig.engine.configure { $0.scanEvents = [] }
        await rig.model.startScan(.quick)
        #expect(rig.model.errorMessage == "The scan ended without a result. Run it again.")
        #expect(rig.model.run == .idle)
    }

    @Test func noScanStartsWhileTheEngineIsNotReady() async {
        let rig = ScannerRig()
        rig.engine.configure { $0.status = .notInstalled }
        await rig.model.refreshStatus()
        await rig.model.startScan(.quick)
        #expect(rig.engine.scans.isEmpty)
    }

    @Test func customRootsInsideTheAppsOwnFoldersAreRejectedUpFront() async {
        let quarantine = URL(fileURLWithPath: "/Users/someone/Library/Application Support/Mainternance/Quarantine")
        let clam = URL(fileURLWithPath: "/Users/someone/Library/Application Support/Mainternance/ClamAV")
        let rig = await ScannerRig.ready(protectedFolders: [quarantine, clam])
        let rejected = [
            quarantine, clam, quarantine.appendingPathComponent("sub"), clam.appendingPathComponent("database"),
            quarantine.deletingLastPathComponent() // a parent would contain both folders
        ]
        for url in rejected {
            await rig.model.startScan(.custom(url))
            #expect(rig.model.errorMessage == ScannerText.protectedFolder, "\(url.path)")
        }
        #expect(rig.engine.scans.isEmpty)
        rig.engine.configure { $0.scanEvents = [.started(scope: .quick), .finished(makeSummary())] }
        await rig.model.startScan(.custom(URL(fileURLWithPath: "/Users/someone/Documents")))
        #expect(rig.engine.scans == [.custom(URL(fileURLWithPath: "/Users/someone/Documents"))])
        #expect(rig.model.errorMessage == nil)
    }

    // MARK: Full Disk Access

    @Test func fullDiskAccessIsOfferedOnlyWhenAccessWasDenied() async throws {
        let rig = await ScannerRig.ready()
        rig.engine.configure {
            $0.scanEvents = [.started(scope: .quick), .finished(makeSummary(unreadable: 5, denied: 3))]
        }
        await rig.model.startScan(.quick)
        #expect(rig.model.needsFullDiskAccess)
        #expect(rig.model.permissionDeniedCount == 3)
        rig.model.openFullDiskAccessSettings()
        let expected = try #require(URL(
            string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_AllFiles"
        ))
        #expect(rig.opened.all == [expected])

        rig.engine.configure {
            $0.scanEvents = [.started(scope: .quick), .finished(makeSummary(unreadable: 5, denied: 0))]
        }
        await rig.model.startScan(.quick)
        #expect(!rig.model.needsFullDiskAccess)
    }
}
