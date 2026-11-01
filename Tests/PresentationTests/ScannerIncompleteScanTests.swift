import Foundation
import MainternanceDomain
@testable import MainternancePresentation
import Testing

/// Detections that could not be attributed to a file in a scan that did not finish still count, until a completed
/// scan replaces them.
@MainActor
struct ScannerIncompleteScanTests {
    /// The engine's events for a scan that fails after `count` detections it could not attribute.
    private func failure(_ count: Int) -> [ScanEvent] {
        [.unattributed(detections: count), .failed(message: "The scan failed (exit 2): ERROR: x")]
    }

    @Test func aCancelledScansUnattributedDetectionsAreKeptAndPersisted() async {
        let rig = await ScannerRig.ready()
        rig.engine.configure {
            $0.scanEvents = [.started(scope: .quick), .finished(makeSummary(unattributed: 3, cancelled: true))]
        }
        await rig.model.startScan(.quick)
        #expect(rig.model.unattributedFromIncompleteScan == 3)
        #expect(rig.store.lastMemory?.unattributedFromIncompleteScan == 3)
        #expect(rig.store.recorded.first?.summary.cancelled == true)
    }

    @Test func aFailedScansUnattributedDetectionsAreKeptAndPersisted() async {
        let rig = await ScannerRig.ready()
        rig.engine.configure { $0.scanEvents = [.started(scope: .quick)] + failure(2) }
        await rig.model.startScan(.quick)
        #expect(rig.model.unattributedFromIncompleteScan == 2)
        #expect(rig.store.remembered.last?.unattributedFromIncompleteScan == 2)
    }

    @Test func aFailureThatNeverStartedChangesNothing() async {
        let rig = await ScannerRig.ready()
        rig.engine.configure { $0.scanEvents = failure(5) }
        await rig.model.startScan(.quick)
        #expect(rig.model.unattributedFromIncompleteScan == 0)
        #expect(rig.store.remembered.isEmpty)
    }

    @Test func twoIncompleteScansKeepTheLargerCount() async {
        let rig = await ScannerRig.ready()
        rig.engine.configure { $0.scanEvents = [.started(scope: .quick)] + failure(4) }
        await rig.model.startScan(.quick)
        rig.engine.configure { $0.scanEvents = [.started(scope: .quick)] + failure(1) }
        await rig.model.startScan(.quick)
        #expect(rig.model.unattributedFromIncompleteScan == 4)
    }

    @Test func aCompletedScanReplacesTheCountWithZero() async {
        let rig = await ScannerRig.ready()
        rig.engine.configure { $0.scanEvents = [.started(scope: .quick)] + failure(4) }
        await rig.model.startScan(.quick)
        await rig.scanFinding([], scope: .quick)
        #expect(rig.model.unattributedFromIncompleteScan == 0)
        #expect(rig.store.lastMemory?.unattributedFromIncompleteScan == 0)
    }

    @Test func aCompletedScansOwnUnattributedCountIsNotDoubleCounted() async {
        let rig = await ScannerRig.ready()
        rig.engine.configure {
            $0.scanEvents = [.started(scope: .quick), .finished(makeSummary(unattributed: 2))]
        }
        await rig.model.startScan(.quick)
        #expect(rig.model.unattributedFromIncompleteScan == 0)
    }

    @Test func aCountInsideAFailureMessageIsNeverTrusted() async {
        let rig = await ScannerRig.ready()
        let hostile = "The scan failed (exit 2)" + ScanFailureNote.unattributedClause(99) + ": " + "evil\nfile name"
        rig.engine.configure { $0.scanEvents = [.started(scope: .quick), .failed(message: hostile)] }
        await rig.model.startScan(.quick)
        #expect(rig.model.unattributedFromIncompleteScan == 0)
        #expect(rig.model.errorMessage == hostile) // the message is still shown as it is
    }

    @Test func theCountComesBackAfterARestart() async {
        let rig = ScannerRig()
        rig.store.state.withLock {
            $0.stored = RecordedScanStatus(summary: nil, findings: [], unattributedFromIncompleteScan: 6)
        }
        await rig.model.refreshStatus()
        #expect(rig.model.unattributedFromIncompleteScan == 6)
    }

    @Test func theMessageIsPluralAwareAndPinned() {
        #expect(ScannerText.unattributedIncomplete(1) == [
            "1 detection from a scan that did not finish could not be attributed to a file (unusual file names).",
            "It stays counted until a scan finishes."
        ].joined(separator: " "))
        #expect(ScannerText.unattributedIncomplete(3).hasPrefix("3 detections from a scan that did not finish"))
    }
}
