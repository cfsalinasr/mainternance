import Foundation
import MainternanceDomain
@testable import MainternancePresentation
import Testing

/// A finished scan may only drop an older finding when it covered the finding's path and did not detect it again.
@MainActor
struct ScannerCoverageTests {
    private let documents = "/Users/someone/Documents/x.pkg"
    private let daemons = "/Library/LaunchDaemons/evil.plist"

    @Test func aFullScanFindingSurvivesALaterQuickScan() async {
        let rig = await ScannerRig.ready()
        let kept = makeFinding(1, path: documents)
        await rig.scanFinding([kept], scope: .full)
        #expect(rig.model.findings == [kept])
        await rig.scanFinding([], scope: .quick)
        #expect(rig.model.findings == [kept])
        #expect(rig.store.lastMemory?.findings == [kept])
    }

    @Test func aQuickFindingOutsideTheFullScanRootsSurvivesAFullScan() async {
        let rig = await ScannerRig.ready()
        rig.engine.configure { $0.roots[.quick] = ["/Users/someone/Downloads", "/Library/LaunchDaemons"] }
        let kept = makeFinding(1, path: daemons)
        await rig.scanFinding([kept], scope: .quick)
        await rig.scanFinding([], scope: .full)
        #expect(rig.model.findings == [kept])
        #expect(rig.store.lastMemory?.findings == [kept])
    }

    @Test func aFindingInsideTheScanRootsThatIsNoLongerDetectedIsDropped() async {
        let rig = await ScannerRig.ready()
        await rig.scanFinding([makeFinding(1), makeFinding(2)], scope: .quick)
        await rig.scanFinding([makeFinding(2, path: makeFinding(2).path)], scope: .quick)
        #expect(rig.model.findings.map(\.path) == [makeFinding(2).path])
        #expect(rig.store.lastMemory?.findings.map(\.path) == [makeFinding(2).path])
    }

    @Test func aFindingInAnExcludedCloudFolderSurvivesAFullScan() async {
        let rig = await ScannerRig.ready()
        let cloud = makeFinding(1, path: "/Users/someone/Library/CloudStorage/Dropbox/x.pkg")
        await rig.scanFinding([cloud], scope: .full)
        await rig.scanFinding([], scope: .full)
        #expect(rig.model.findings == [cloud])
    }

    @Test func aFindingDetectedAgainIsRefreshedNotDuplicated() async {
        let rig = await ScannerRig.ready()
        await rig.scanFinding([makeFinding(1)], scope: .quick)
        let again = makeFinding(7, path: makeFinding(1).path)
        await rig.scanFinding([again], scope: .quick)
        #expect(rig.model.findings == [again])
    }

    @Test func pathsAreComparedByWholeComponents() async {
        let rig = await ScannerRig.ready()
        let lookalike = makeFinding(1, path: "/Users/someone/Downloads2/x.pkg")
        await rig.scanFinding([lookalike], scope: .full)
        rig.engine.configure { $0.roots[.quick] = ["/Users/someone/Downloads"] }
        await rig.scanFinding([], scope: .quick)
        #expect(rig.model.findings == [lookalike])
    }

    @Test func startingAScanKeepsTheOldListVisibleWhileItRuns() async {
        let rig = await ScannerRig.ready()
        await rig.scanFinding([makeFinding(1)], scope: .quick)
        rig.engine.configure { $0.holdScan = true; $0.scanEvents = [.started(scope: .quick)] }
        let scan = Task { await rig.model.startScan(.quick) }
        var calls = rig.engine.scanCalls.makeAsyncIterator()
        _ = await calls.next() // the first scan call
        _ = await calls.next()
        #expect(rig.model.findings == [makeFinding(1)])
        rig.engine.emit(.progress(scanned: 1, current: "/x"))
        #expect(await rig.model.wait { rig.model.run == .scanning(scanned: 1, current: "/x") })
        #expect(rig.model.findings == [makeFinding(1)])
        rig.engine.finishScan()
        await scan.value
    }

    @Test func aNewFindingShowsUpWhileTheScanIsStillRunning() async {
        let rig = await ScannerRig.ready()
        rig.engine.configure { $0.holdScan = true; $0.scanEvents = [.started(scope: .quick), .found(makeFinding(1))] }
        let scan = Task { await rig.model.startScan(.quick) }
        #expect(await rig.model.wait { rig.model.findings == [makeFinding(1)] })
        rig.engine.emit(.finished(makeSummary(findings: 1)))
        rig.engine.finishScan()
        await scan.value
        #expect(rig.model.findings == [makeFinding(1)])
    }

    @Test func aCancelledOrFailedScanNeverDropsAnything() async {
        let rig = await ScannerRig.ready()
        await rig.scanFinding([makeFinding(1)], scope: .quick)
        rig.engine.configure {
            $0.scanEvents = [.started(scope: .quick), .finished(makeSummary(cancelled: true))]
        }
        await rig.model.startScan(.quick)
        #expect(rig.model.findings == [makeFinding(1)])
        rig.engine.configure { $0.scanEvents = [.started(scope: .quick), .failed(message: "stopped")] }
        await rig.model.startScan(.quick)
        #expect(rig.model.findings == [makeFinding(1)])
    }
}
