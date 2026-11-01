import Foundation
import MainternanceDomain
@testable import MainternancePresentation
import Testing

/// A completed scan may only resolve a finding in a folder it could really read, unless the file is gone.
@MainActor
struct ScannerUnreadableTests {
    private func completedScan(
        _ rig: ScannerRig, unreadable: Int = 0, denied: Int = 0, unattributed: Int = 0
    ) async {
        rig.engine.configure {
            $0.scanEvents = [
                .started(scope: .quick),
                .finished(makeSummary(unreadable: unreadable, denied: denied, unattributed: unattributed))
            ]
        }
        await rig.model.startScan(.quick)
    }

    private func rigWithOneFinding() async -> ScannerRig {
        let rig = await ScannerRig.ready()
        await rig.scanFinding([makeFinding(1)])
        return rig
    }

    @Test func aFullyReadableScanDropsACoveredFindingItNoLongerSees() async {
        let rig = await rigWithOneFinding()
        await completedScan(rig)
        #expect(rig.model.findings.isEmpty)
    }

    @Test func unreadableFilesKeepTheFindingOfAFileThatStillExists() async {
        let rig = await rigWithOneFinding()
        await completedScan(rig, unreadable: 2)
        #expect(rig.model.findings == [makeFinding(1)])
        #expect(rig.store.lastMemory?.findings == [makeFinding(1)])
    }

    @Test func unreadableFilesStillDropTheFindingOfAFileThatIsGone() async {
        let rig = await rigWithOneFinding()
        rig.files.remove(makeFinding(1).path)
        await completedScan(rig, unreadable: 2)
        #expect(rig.model.findings.isEmpty)
    }

    @Test func permissionDeniedKeepsTheFinding() async {
        let rig = await rigWithOneFinding()
        await completedScan(rig, unreadable: 1, denied: 1)
        #expect(rig.model.findings == [makeFinding(1)])
    }

    @Test func unattributedDetectionsKeepTheFinding() async {
        let rig = await rigWithOneFinding()
        await completedScan(rig, unattributed: 1)
        #expect(rig.model.findings == [makeFinding(1)])
    }

    @Test func aGoneFileIsDroppedEvenWhenNothingWasUnreadable() async {
        let rig = await rigWithOneFinding()
        rig.files.remove(makeFinding(1).path)
        await completedScan(rig)
        #expect(rig.model.findings.isEmpty)
    }

    @Test func aFindingTheScanDetectsAgainIsKeptNoMatterWhat() async {
        let rig = await rigWithOneFinding()
        rig.files.remove(makeFinding(1).path)
        await rig.scanFinding([makeFinding(1)])
        #expect(rig.model.findings.map(\.path) == [makeFinding(1).path])
    }

    @Test func theDefaultExistenceCheckSeesRealFilesAndRealGaps() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("mainternance-exists-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("a.bin")
        try Data("x".utf8).write(to: file)
        let link = folder.appendingPathComponent("dangling")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: folder.path + "/nowhere")
        #expect(pathStillExists(file.path))
        #expect(pathStillExists(link.path)) // a dangling link is still something there: it is not followed
        #expect(!pathStillExists(folder.appendingPathComponent("gone.bin").path))
    }

    @Test func coverageIsTakenWhenTheScanStartsNotWhenItEnds() async {
        let rig = await ScannerRig.ready()
        await rig.scanFinding([makeFinding(1)])
        rig.engine.configure {
            $0.holdScan = true
            $0.scanEvents = [.started(scope: .quick)]
        }
        let scan = Task { await rig.model.startScan(.quick) }
        var calls = rig.engine.scanCalls.makeAsyncIterator()
        _ = await calls.next() // the first scan
        _ = await calls.next() // this one
        // The scope's folders change while the scan runs; what the scan actually walked is what counted at its start.
        rig.engine.configure { $0.roots[.quick] = [] }
        rig.engine.emit(.finished(makeSummary()))
        rig.engine.finishScan()
        await scan.value
        #expect(rig.model.findings.isEmpty)
    }

    @Test func coverageTakenAtStartAlsoProtectsWhenTheFoldersAppearLater() async {
        let rig = await ScannerRig.ready()
        rig.engine.configure { $0.roots[.quick] = [] }
        await rig.scanFinding([makeFinding(1)], scope: .full)
        rig.engine.configure {
            $0.holdScan = true
            $0.scanEvents = [.started(scope: .quick)]
        }
        let scan = Task { await rig.model.startScan(.quick) }
        var calls = rig.engine.scanCalls.makeAsyncIterator()
        _ = await calls.next()
        _ = await calls.next()
        rig.engine.configure { $0.roots[.quick] = ["/Users/someone/Downloads"] }
        rig.engine.emit(.finished(makeSummary()))
        rig.engine.finishScan()
        await scan.value
        #expect(rig.model.findings == [makeFinding(1)])
    }
}
