import Foundation
import MainternanceDomain
@testable import MainternancePresentation
import Testing

@MainActor
struct ScannerQuarantineTests {
    // MARK: Quarantine

    @Test func confirmWithoutARequestDoesNothing() async {
        let rig = await ScannerRig.ready()
        await rig.scanFinding([makeFinding(1)])
        await rig.model.confirmQuarantine()
        #expect(rig.log.all.filter { $0 != "scan" }.isEmpty)
        #expect(rig.model.findings == [makeFinding(1)])
    }

    @Test func requestOfAnUnknownOrAlreadyQuarantinedIdDoesNotOpenTheSheet() async {
        let rig = await ScannerRig.ready()
        await rig.scanFinding([makeFinding(1)])
        rig.engine.configure { $0.verifyDefault = .confirmed(signature: "Win.Test.EICAR_HDB-1") }
        rig.model.requestQuarantine(UUID())
        #expect(rig.model.pendingQuarantine == nil)
        rig.model.requestQuarantine(makeFinding(1).id)
        await rig.model.confirmQuarantine()
        #expect(rig.model.findings.isEmpty)
        rig.model.requestQuarantine(makeFinding(1).id) // now quarantined, no longer a finding
        #expect(rig.model.pendingQuarantine == nil)
    }

    @Test func cancellingTheSheetClearsTheRequestAndMovesNothing() async {
        let rig = await ScannerRig.ready()
        await rig.scanFinding([makeFinding(1)])
        rig.model.requestQuarantine(makeFinding(1).id)
        #expect(rig.model.pendingQuarantine == makeFinding(1))
        rig.model.cancelQuarantine()
        #expect(rig.model.pendingQuarantine == nil)
        await rig.model.confirmQuarantine()
        #expect(rig.quarantine.calls.isEmpty)
    }

    @Test func confirmVerifiesFirstThenQuarantinesExactlyTheRequestedFinding() async {
        let rig = await ScannerRig.ready()
        let first = makeFinding(1)
        let second = makeFinding(2, signature: "Other.Sig")
        await rig.scanFinding([first, second])
        rig.engine.configure { $0.verify[second.path] = .confirmed(signature: "Other.Sig") }
        rig.model.requestQuarantine(second.id)
        await rig.model.confirmQuarantine()
        #expect(rig.log.all == ["scan", "verify", "quarantine"])
        #expect(rig.engine.verified == [second.path])
        #expect(rig.quarantine.calls.count == 1)
        #expect(rig.quarantine.calls.first?.path == second.path)
        #expect(rig.quarantine.calls.first?.signature == "Other.Sig")
        #expect(rig.model.findings == [first])
        #expect(rig.model.quarantined.map(\.originalPath) == [second.path])
        #expect(rig.store.remembered.last?.findings == [first])
        #expect(rig.model
            .notice == "file2.bin was moved to the quarantine folder. You can restore it from the list below.")
        #expect(rig.model.errorMessage == nil)
        #expect(rig.model.pendingQuarantine == nil)
    }

    @Test func aFileThatNoLongerLooksInfectedIsNotMovedAndStaysListed() async {
        let rig = await ScannerRig.ready()
        await rig.scanFinding([makeFinding(1)])
        rig.engine.configure { $0.verifyDefault = .clean }
        rig.model.requestQuarantine(makeFinding(1).id)
        await rig.model.confirmQuarantine()
        #expect(rig.quarantine.calls.isEmpty)
        #expect(rig.model.findings == [makeFinding(1)])
        #expect(rig.model
            .errorMessage == "file1.bin no longer looks infected, so it was not moved. Scan again to update the list.")
    }

    @Test func aFailedRecheckShowsItsMessageAndMovesNothing() async {
        let rig = await ScannerRig.ready()
        await rig.scanFinding([makeFinding(1)])
        rig.engine.configure { $0.verifyDefault = .failed(message: "The file could not be checked (exit 2)") }
        rig.model.requestQuarantine(makeFinding(1).id)
        await rig.model.confirmQuarantine()
        #expect(rig.quarantine.calls.isEmpty)
        #expect(rig.model.findings == [makeFinding(1)])
        #expect(rig.model.errorMessage ==
            "The file could not be checked again, so it was not moved. The file could not be checked (exit 2)")
    }

    @Test func aDifferentSignatureIsRefused() async {
        let rig = await ScannerRig.ready()
        await rig.scanFinding([makeFinding(1)])
        rig.engine.configure { $0.verifyDefault = .confirmed(signature: "Something.Else") }
        rig.model.requestQuarantine(makeFinding(1).id)
        await rig.model.confirmQuarantine()
        #expect(rig.quarantine.calls.isEmpty)
        #expect(rig.model.findings == [makeFinding(1)])
        #expect(rig.model.errorMessage?.contains("Something.Else") == true)
    }

    @Test func quarantineErrorsLeaveTheFindingAndExplainInPlainWords() async {
        let cases: [(QuarantineError, String)] = [
            (.changedSinceScan, "The file changed since the scan, so it was not moved. Scan again to check it."),
            (
                .protectedPath,
                "This file is in a protected location (a system, app or home folder), so it was not moved."
            ),
            (
                .notRegularFile,
                "Only regular files can be quarantined. This is a folder, link or special file, so it was not moved."
            ),
            (.missing, "The file is no longer there, so nothing was moved."),
            (.ioFailure("Disk full"), "The file could not be moved: Disk full. It was left where it is.")
        ]
        for (error, text) in cases {
            let rig = await ScannerRig.ready()
            await rig.scanFinding([makeFinding(1)])
            rig.engine.configure { $0.verifyDefault = .confirmed(signature: "Win.Test.EICAR_HDB-1") }
            rig.quarantine.configure { $0.quarantineError = error }
            rig.model.requestQuarantine(makeFinding(1).id)
            await rig.model.confirmQuarantine()
            #expect(rig.model.findings == [makeFinding(1)], "\(error)")
            #expect(rig.model.errorMessage == text, "\(error)")
            #expect(rig.model.quarantined.isEmpty)
            #expect(!rig.model.isQuarantining)
        }
    }

    @Test func quarantineIsNotOfferedWhileAScanRuns() async {
        let rig = await ScannerRig.ready()
        await rig.scanFinding([makeFinding(1)])
        rig.engine.configure { $0.holdScan = true; $0.scanEvents = [.started(scope: .quick), .found(makeFinding(2))] }
        let scan = Task { await rig.model.startScan(.quick) }
        var calls = rig.engine.scanCalls.makeAsyncIterator()
        _ = await calls.next() // the first scan call was consumed by scanFinding; wait for this one
        _ = await calls.next()
        // Finding 2 must be listed while the scan still runs, so only the busy guard can refuse it.
        #expect(await rig.model.wait { rig.model.findings.contains(makeFinding(2)) && rig.model.run.isWorking })
        rig.model.requestQuarantine(makeFinding(2).id)
        #expect(rig.model.pendingQuarantine == nil)
        rig.engine.finishScan()
        await scan.value
    }

    // MARK: Restore

    @Test func restoreMovesAFindingOfThisScanBackToTheFindings() async throws {
        let rig = await ScannerRig.ready()
        await rig.scanFinding([makeFinding(1), makeFinding(2)])
        rig.engine.configure { $0.verifyDefault = .confirmed(signature: "Win.Test.EICAR_HDB-1") }
        rig.model.requestQuarantine(makeFinding(1).id)
        await rig.model.confirmQuarantine()
        let record = try #require(rig.model.quarantined.first)
        await rig.model.restore(record.id)
        #expect(Set(rig.model.findings.map(\.id)) == [makeFinding(1).id, makeFinding(2).id])
        #expect(rig.model.quarantined.isEmpty)
        #expect(rig.store.remembered.last?.findings.count == 2)
        let expected = [
            "Restored to /Users/someone/Downloads/file1.bin.",
            "It was flagged as Win.Test.EICAR_HDB-1, so be careful with it."
        ].joined(separator: " ")
        #expect(rig.model.notice == expected)
    }

    @Test func restoreOfARecordThatWasNeverLinkedToAFindingDoesNotInventOne() async {
        let rig = ScannerRig()
        let old = QuarantineRecord(
            id: UUID(), originalPath: "/Users/someone/old.bin", quarantinedAt: testNow, signature: "Old.Sig",
            sha256: "00", size: 1, originalPermissions: 0o644
        )
        rig.quarantine.configure { $0.stored = [old] }
        await rig.model.refreshStatus()
        #expect(rig.model.quarantined == [old])
        await rig.model.restore(old.id)
        #expect(rig.model.findings.isEmpty)
        #expect(rig.model.quarantined.isEmpty)
        #expect(rig.store.remembered.isEmpty)
    }

    @Test func aRestoreErrorIsShownAndTheRecordStays() async {
        let rig = ScannerRig()
        let old = QuarantineRecord(
            id: UUID(), originalPath: "/gone/old.bin", quarantinedAt: testNow, signature: "Old.Sig",
            sha256: "00", size: 1, originalPermissions: 0o644
        )
        rig.quarantine.configure { $0.stored = [old]; $0.restoreError = .restoreTargetMissing }
        await rig.model.refreshStatus()
        await rig.model.restore(old.id)
        #expect(rig.model.errorMessage == "The folder this file came from no longer exists, so it was not restored.")
        #expect(rig.model.quarantined == [old])
    }

    // MARK: Honest quarantine section

    @Test func filesThatCouldNotBeMovedAreNeverListedAsContained() async {
        let rig = ScannerRig()
        let stuck = QuarantineRecord(
            id: UUID(), originalPath: "/Users/someone/stuck.bin", quarantinedAt: testNow, signature: "Stuck.Sig",
            sha256: "00", size: 1, originalPermissions: 0o644
        )
        rig.quarantine.configure { $0.inPlace = [stuck]; $0.unclaimed = ["a", "b"] }
        await rig.model.refreshStatus()
        #expect(rig.model.quarantined.isEmpty)
        #expect(rig.model.notMoved == [stuck])
        #expect(rig.model.unclaimedCount == 2)
    }

    // MARK: Remembering the last scan

    @Test func theLastScanAndItsFindingsComeBackAfterARestart() async {
        let rig = ScannerRig()
        let summary = makeSummary(findings: 1)
        rig.store.state.withLock { $0.stored = RecordedScanStatus(summary: summary, findings: [makeFinding(1)]) }
        await rig.model.refreshStatus()
        #expect(rig.model.findings == [makeFinding(1)])
        #expect(rig.model.run == .finished(summary))
    }

    @Test func restoringHappensOnceAndNeverOverwritesALiveScan() async {
        let rig = ScannerRig()
        rig.store.state.withLock { $0.stored = RecordedScanStatus(summary: nil, findings: [makeFinding(1)]) }
        await rig.model.refreshStatus()
        #expect(rig.model.findings == [makeFinding(1)])
        await rig.scanFinding([makeFinding(2)])
        await rig.model.refreshStatus()
        #expect(rig.model.findings == [makeFinding(2)])
    }
}
