import Foundation
import MainternanceDomain
@testable import MainternancePresentation
import Testing

/// The unattributed count of an unfinished scan is only reset by a completed scan that really covers its scope.
@MainActor
struct ScannerUnattributedScopeTests {
    private func incomplete(_ rig: ScannerRig, _ scope: ScanScope, count: Int) async {
        rig.engine.configure {
            $0.scanEvents = [.started(scope: scope), .unattributed(detections: count), .failed(message: "stopped")]
        }
        await rig.model.startScan(scope)
    }

    private func completed(_ rig: ScannerRig, _ scope: ScanScope, unattributed: Int = 0) async {
        rig.engine.configure {
            $0.scanEvents = [.started(scope: scope), .finished(makeSummary(scope: scope, unattributed: unattributed))]
        }
        await rig.model.startScan(scope)
    }

    @Test func theScopeIsStoredWithTheCount() async {
        let rig = await ScannerRig.ready()
        await incomplete(rig, .full, count: 2)
        #expect(rig.model.unattributedScope == .full)
        #expect(rig.store.lastMemory?.unattributedScope == .full)
        #expect(rig.store.lastMemory?.unattributedFromIncompleteScan == 2)
    }

    @Test func aCompletedQuickScanDoesNotResetAFullScansCount() async {
        let rig = await ScannerRig.ready()
        await incomplete(rig, .full, count: 2)
        await completed(rig, .quick)
        #expect(rig.model.unattributedFromIncompleteScan == 2)
        #expect(rig.model.unattributedScope == .full)
    }

    @Test func aCompletedFullScanResetsAQuickScansCount() async {
        let rig = await ScannerRig.ready()
        await incomplete(rig, .quick, count: 2)
        await completed(rig, .full)
        #expect(rig.model.unattributedFromIncompleteScan == 0)
        #expect(rig.model.unattributedScope == nil)
    }

    @Test func aCompletedScanOfTheSameScopeResetsTheCount() async {
        let rig = await ScannerRig.ready()
        await incomplete(rig, .quick, count: 3)
        await completed(rig, .quick)
        #expect(rig.model.unattributedFromIncompleteScan == 0)
        let custom = ScanScope.custom(URL(fileURLWithPath: "/Users/someone/Documents"))
        rig.engine.configure { $0.roots[custom] = ["/Users/someone/Documents"] }
        await incomplete(rig, custom, count: 1)
        await completed(rig, custom)
        #expect(rig.model.unattributedFromIncompleteScan == 0)
    }

    @Test func aCompletedScanWithUnattributedDetectionsOfItsOwnResetsNothing() async {
        let rig = await ScannerRig.ready()
        await incomplete(rig, .quick, count: 2)
        await completed(rig, .full, unattributed: 1)
        #expect(rig.model.unattributedFromIncompleteScan == 2)
    }

    @Test func aDifferentCustomScopeDoesNotResetIt() async {
        let rig = await ScannerRig.ready()
        let first = ScanScope.custom(URL(fileURLWithPath: "/Users/someone/A"))
        let second = ScanScope.custom(URL(fileURLWithPath: "/Users/someone/B"))
        await incomplete(rig, first, count: 2)
        await completed(rig, second)
        #expect(rig.model.unattributedFromIncompleteScan == 2)
    }

    @Test func countsOfTheSameScopeKeepTheLargerOneAndDifferentScopesAddUp() async {
        let rig = await ScannerRig.ready()
        await incomplete(rig, .quick, count: 4)
        await incomplete(rig, .quick, count: 1)
        #expect(rig.model.unattributedFromIncompleteScan == 4)
        await incomplete(rig, .full, count: 2)
        #expect(rig.model.unattributedFromIncompleteScan == 6)
        #expect(rig.model.unattributedScope == .full) // the broader scope, so a quick scan cannot reset it
        await completed(rig, .quick)
        #expect(rig.model.unattributedFromIncompleteScan == 6)
    }

    @Test func anIncompleteScanWithNothingUnattributedChangesNothing() async {
        let rig = await ScannerRig.ready()
        await incomplete(rig, .full, count: 2)
        rig.engine.configure { $0.scanEvents = [.started(scope: .quick), .failed(message: "stopped")] }
        await rig.model.startScan(.quick)
        #expect(rig.model.unattributedFromIncompleteScan == 2)
        #expect(rig.model.unattributedScope == .full)
    }

    @Test func theScopeComesBackAfterARestart() async {
        let rig = ScannerRig()
        rig.store.state.withLock {
            $0.stored = RecordedScanStatus(
                summary: nil, findings: [], unattributedFromIncompleteScan: 2, unattributedScope: .full
            )
        }
        await rig.model.refreshStatus()
        #expect(rig.model.unattributedScope == .full)
        #expect(rig.model.unattributedFromIncompleteScan == 2)
    }
}
