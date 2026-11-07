import Foundation
import MainternanceDomain
@testable import MainternancePresentation
import Testing

/// A quarantine list that cannot be read is never shown as "nothing in quarantine": the section stays, says so,
/// and keeps what the last good read showed.
@MainActor
struct ScannerQuarantineUnreadableTests {
    private func record(_ index: Int) -> QuarantineRecord {
        QuarantineRecord(
            id: UUID(), originalPath: makeFinding(index).path, quarantinedAt: testNow, signature: "Test.Sig",
            sha256: "00", size: 1, originalPermissions: 0o644
        )
    }

    @Test func anUnreadableListShowsTheSectionWithANote() async {
        let rig = await ScannerRig.ready()
        rig.quarantine.state.withLock { $0.listError = .ioFailure("Permission denied") }
        await rig.model.refreshStatus()
        #expect(rig.model.quarantineUnreadable)
        #expect(rig.model.showsQuarantineSection) // not hidden, as an empty quarantine would be
        #expect(rig.model.quarantined.isEmpty)
    }

    @Test func heldFilesStayListedWhileTheListCannotBeRead() async {
        let rig = await ScannerRig.ready()
        let held = record(1)
        rig.quarantine.state.withLock { $0.stored = [held] }
        await rig.model.refreshStatus()
        #expect(rig.model.quarantined == [held])
        rig.quarantine.state.withLock { $0.listError = .ioFailure("Input/output error") }
        await rig.model.refreshStatus()
        #expect(rig.model.quarantineUnreadable)
        #expect(rig.model.quarantined == [held]) // the last good read, so Restore stays reachable
    }

    @Test func theNoteGoesOnceTheListCanBeReadAgain() async {
        let rig = await ScannerRig.ready()
        rig.quarantine.state.withLock { $0.listError = .ioFailure("Permission denied") }
        await rig.model.refreshStatus()
        rig.quarantine.state.withLock { $0.listError = nil }
        await rig.model.refreshStatus()
        #expect(!rig.model.quarantineUnreadable)
        #expect(!rig.model.showsQuarantineSection) // an empty, readable quarantine has no section
    }

    @Test func theNoteIsPlain() {
        #expect(ScannerText.quarantineUnreadable
            == "The quarantine list could not be read, so what is shown may be out of date. Nothing was removed.")
    }

    @Test func anOlderReloadCannotDropTheLinkOfAFileMovedMeanwhile() async {
        let rig = await ScannerRig.ready()
        let held = record(1)
        let finding = makeFinding(2)
        await rig.scanFinding([finding])
        rig.engine.configure { $0.verifyDefault = .confirmed(signature: finding.signature) }
        rig.quarantine.state.withLock {
            $0.stored = [held]
            $0.holdNextUnclaimed = true
        }
        // 1. An older reload reads the list (without the new file) and waits before applying it.
        let older = Task { @MainActor in await rig.model.reloadQuarantine() }
        var reached = rig.quarantine.unclaimedReached.makeAsyncIterator()
        await reached.next()
        // 2. The file is moved and linked to its finding; the action waits while saving that link.
        rig.store.state.withLock { $0.holdNextRemember = true }
        rig.model.requestQuarantine(finding.id)
        let action = Task { @MainActor in await rig.model.confirmQuarantine() }
        var saving = rig.store.rememberReached.makeAsyncIterator()
        await saving.next()
        // 3. The older reload resumes now, before the action's own reload: it must be dropped as stale.
        rig.quarantine.releaseUnclaimed()
        await older.value
        rig.store.releaseRemember()
        await action.value
        let newID = rig.quarantine.state.withLock { $0.stored.last?.id }
        #expect(rig.model.quarantined.count == 2)
        #expect(rig.model.resolvedByQuarantine.count == 1)
        if let newID {
            await rig.model.restore(newID)
            #expect(rig.model.findings.contains { $0.path == finding.path }) // its finding is back
        }
    }
}
