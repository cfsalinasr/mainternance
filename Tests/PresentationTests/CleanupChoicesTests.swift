import Foundation
import MainternanceDomain
@testable import MainternancePresentation
import Testing

/// The owner's ticks and unticks survive every later measuring, and an old move's result never sits under a new
/// list or claims "Moved 0 items".
@MainActor
@Suite("Cleanup keeps the owner's choices")
struct CleanupChoicesTests {
    private let big = CleanupRig.path("big")
    private let small = CleanupRig.path("small")
    private let log = CleanupRig.path("app.log", folder: "/Users/me/Library/Logs")
    private let installer = CleanupRig.path("Old.dmg", folder: CleanupRig.downloads)

    @Test("coming back to the screen measures again but keeps what the owner unticked and ticked")
    func choicesSurviveComingBack() async {
        let rig = CleanupRig(CleanupRig.withInstaller)
        await rig.state.appear()
        rig.state.toggleEntry(small) // unticked a cache
        rig.state.toggleEntry(installer) // ticked an old installer
        await rig.state.appear() // left for Home and came back
        #expect(rig.fake.measures == 2)
        #expect(!rig.state.isSelected(entry: small))
        #expect(rig.state.isSelected(entry: installer))
        #expect(rig.state.selectedEntries.map(\.id) == [big, log, installer])
    }

    @Test("a new entry gets its category's default; known ones keep the owner's choice")
    func newEntriesGetDefaults() async {
        let rig = CleanupRig()
        await rig.state.measure()
        rig.state.toggleCategory(.caches) // unticks big and small
        var grown = CleanupRig.withInstaller
        grown.categories[0].entries.append(CleanupRig.entry("fresh", 10))
        rig.fake.configure { $0.measurement = grown }
        await rig.state.measure()
        let fresh = CleanupRig.path("fresh")
        #expect(rig.state.isSelected(entry: fresh))
        #expect(!rig.state.isSelected(entry: big))
        #expect(!rig.state.isSelected(entry: small))
        #expect(!rig.state.isSelected(entry: installer)) // new installer: never ticked by default
        #expect(rig.state.isSelected(entry: log))
    }

    @Test("an untick made while a measuring runs is not lost when it finishes")
    func toggleDuringMeasuring() async {
        let gate = GatedCleanupScanner()
        let rig = CleanupRig(scanner: gate)
        let first = Task { await rig.state.measure() }
        await gate.waitForCall(1)
        gate.release(CleanupRig.sample)
        await first.value
        let second = Task { await rig.state.measure() }
        await gate.waitForCall(1)
        #expect(rig.state.isMeasuring)
        rig.state.toggleEntry(big)
        gate.release(CleanupRig.sample)
        await second.value
        #expect(!rig.state.isSelected(entry: big))
        #expect(rig.state.selectedEntries.map(\.id) == [small, log])
    }

    @Test("a measuring after a move clears that move's result card")
    func measuringClearsOldResult() async {
        let rig = CleanupRig()
        rig.fake.configure { $0.failing = [big: "It is in use."] }
        await rig.state.measure()
        rig.state.review()
        await rig.state.confirm()
        #expect(rig.state.showsResultCard)
        #expect(!rig.state.failureLines.isEmpty)
        await rig.state.measure()
        #expect(rig.state.lastOutcome == nil)
        #expect(rig.state.resultText == nil)
        #expect(rig.state.failureLines.isEmpty)
        #expect(!rig.state.showsResultCard)
    }

    @Test("when nothing moved, the card says only 'Nothing was moved', never 'Moved 0 items'")
    func nothingMovedHasNoZeroCount() async {
        let rig = CleanupRig()
        rig.fake.configure { $0.failing = [big: "No.", small: "No.", log: "No."] }
        await rig.state.measure()
        rig.state.review()
        await rig.state.confirm()
        #expect(rig.state.resultText == nil) // the trash note hangs on it, so it is hidden too
        #expect(rig.state.message == CleanupText.nothingMoved)
        #expect(rig.state.showsResultCard)
        #expect(CleanupText.result(CleanupOutcome(moved: [], failed: [])) == nil)
    }

    @Test("a moved path that shows up again later is a new item with its default")
    func movedPathStartsFresh() async {
        let rig = CleanupRig(CleanupRig.withInstaller)
        await rig.state.measure()
        rig.state.toggleEntry(installer) // ticked by the owner
        for id in [big, small, log] {
            rig.state.toggleEntry(id)
        }
        rig.state.review()
        await rig.state.confirm()
        #expect(rig.fake.moves == [[installer]])
        await rig.state.measure() // a new Old.dmg appeared at the same path
        #expect(!rig.state.isSelected(entry: installer))
    }
}
