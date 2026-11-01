import Foundation
import MainternanceDomain
@testable import MainternancePresentation
import Testing

/// The link between a quarantined file and the finding it resolved is remembered, so a restore puts the finding
/// back even after a restart or a later cancelled or failed scan.
@MainActor
struct ScannerRestoreTests {
    private let signature = "Win.Test.EICAR_HDB-1"

    private func quarantineOne(_ rig: ScannerRig, _ finding: ScanFinding) async throws -> QuarantineRecord {
        rig.engine.configure { $0.verifyDefault = .confirmed(signature: signature) }
        rig.model.requestQuarantine(finding.id)
        await rig.model.confirmQuarantine()
        return try #require(rig.model.quarantined.first { $0.originalPath == finding.path })
    }

    private func record(for finding: ScanFinding, id: UUID = UUID()) -> QuarantineRecord {
        QuarantineRecord(
            id: id, originalPath: finding.path, quarantinedAt: testNow, signature: finding.signature,
            sha256: "00", size: 1, originalPermissions: 0o644
        )
    }

    @Test func quarantiningRemembersTheLinkAndTheRemainingFindings() async throws {
        let rig = await ScannerRig.ready()
        await rig.scanFinding([makeFinding(1), makeFinding(2)])
        let stored = try await quarantineOne(rig, makeFinding(1))
        let memory = try #require(rig.store.lastMemory)
        #expect(memory.findings == [makeFinding(2)])
        #expect(memory.resolvedByQuarantine == [stored.id: makeFinding(1)])
    }

    @Test func restoreBringsTheFindingBackAndForgetsTheLink() async throws {
        let rig = await ScannerRig.ready()
        await rig.scanFinding([makeFinding(1)])
        let stored = try await quarantineOne(rig, makeFinding(1))
        await rig.model.restore(stored.id)
        #expect(rig.model.findings == [makeFinding(1)])
        #expect(rig.store.lastMemory?.findings == [makeFinding(1)])
        #expect(rig.store.lastMemory?.resolvedByQuarantine.isEmpty == true)
    }

    @Test func restoreAfterARestartBringsTheFindingBack() async {
        let rig = ScannerRig()
        let finding = makeFinding(1)
        let held = record(for: finding)
        rig.quarantine.configure { $0.stored = [held] }
        rig.store.state.withLock {
            $0.stored = RecordedScanStatus(summary: nil, findings: [], resolvedByQuarantine: [held.id: finding])
        }
        await rig.model.refreshStatus()
        #expect(rig.model.findings.isEmpty)
        await rig.model.restore(held.id)
        #expect(rig.model.findings == [finding])
        #expect(rig.store.lastMemory?.resolvedByQuarantine.isEmpty == true)
    }

    @Test func restoreAfterALaterCancelledScanStillBringsTheFindingBack() async throws {
        let rig = await ScannerRig.ready()
        await rig.scanFinding([makeFinding(1)])
        let stored = try await quarantineOne(rig, makeFinding(1))
        rig.engine.configure {
            $0.scanEvents = [.started(scope: .quick), .finished(makeSummary(cancelled: true))]
        }
        await rig.model.startScan(.quick)
        await rig.model.restore(stored.id)
        #expect(rig.model.findings == [makeFinding(1)])
    }

    @Test func restoreAfterALaterFailedScanStillBringsTheFindingBack() async throws {
        let rig = await ScannerRig.ready()
        await rig.scanFinding([makeFinding(1)])
        let stored = try await quarantineOne(rig, makeFinding(1))
        rig.engine.configure { $0.scanEvents = [.started(scope: .quick), .failed(message: "stopped")] }
        await rig.model.startScan(.quick)
        await rig.model.restore(stored.id)
        #expect(rig.model.findings == [makeFinding(1)])
    }

    @Test func aCompletedScanThatCoversThePathClearsTheLink() async throws {
        let rig = await ScannerRig.ready()
        await rig.scanFinding([makeFinding(1)])
        let stored = try await quarantineOne(rig, makeFinding(1))
        await rig.scanFinding([], scope: .quick) // covers Downloads
        #expect(rig.store.lastMemory?.resolvedByQuarantine.isEmpty == true)
        await rig.model.restore(stored.id)
        #expect(rig.model.findings.isEmpty)
    }

    @Test func aCompletedScanThatDoesNotCoverThePathKeepsTheLink() async throws {
        let rig = await ScannerRig.ready()
        rig.engine.configure { $0.roots[.quick] = ["/Users/someone/Downloads", "/Library/LaunchDaemons"] }
        let outside = makeFinding(1, path: "/Library/LaunchDaemons/evil.plist")
        await rig.scanFinding([outside], scope: .quick)
        let stored = try await quarantineOne(rig, outside)
        await rig.scanFinding([], scope: .full) // the home folder and Applications only
        #expect(rig.store.lastMemory?.resolvedByQuarantine == [stored.id: outside])
        await rig.model.restore(stored.id)
        #expect(rig.model.findings == [outside])
    }

    @Test func aRestoreThatFailsKeepsTheLink() async throws {
        let rig = await ScannerRig.ready()
        await rig.scanFinding([makeFinding(1)])
        let stored = try await quarantineOne(rig, makeFinding(1))
        rig.quarantine.configure { $0.restoreError = .restoreTargetMissing }
        await rig.model.restore(stored.id)
        #expect(rig.model.findings.isEmpty)
        #expect(rig.store.lastMemory?.resolvedByQuarantine == [stored.id: makeFinding(1)])
    }

    @Test func aRestoreBlocksEverythingElseAndADoubleClickDoesNothing() async throws {
        let rig = await ScannerRig.ready()
        await rig.scanFinding([makeFinding(1), makeFinding(2)])
        let stored = try await quarantineOne(rig, makeFinding(1))
        rig.quarantine.configure { $0.holdRestore = true }
        let first = Task { await rig.model.restore(stored.id) }
        var calls = rig.quarantine.restoreCalls.makeAsyncIterator()
        _ = await calls.next()
        #expect(rig.model.isBusy)
        #expect(rig.model.isRestoring)
        #expect(!rig.model.canStartScan)
        #expect(!rig.model.canUpdateDefinitions)
        rig.model.requestQuarantine(makeFinding(2).id)
        #expect(rig.model.pendingQuarantine == nil)
        await rig.model.restore(stored.id) // the double click: it returns at once and starts nothing
        rig.quarantine.releaseRestore()
        await first.value
        #expect(rig.quarantine.state.withLock { $0.restoredIDs } == [stored.id])
        #expect(!rig.model.isRestoring)
        #expect(rig.model.findings.count == 2)
    }
}
