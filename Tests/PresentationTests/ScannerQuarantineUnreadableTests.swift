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
}
