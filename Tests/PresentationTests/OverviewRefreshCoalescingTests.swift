import MainternanceDomain
import MainternancePresentation
import Testing

/// `refresh()` calls that overlap (the loop and "Scan now") share one load and one history sample.
@MainActor
struct OverviewRefreshCoalescingTests {
    private func settle() async {
        for _ in 0 ..< 50 {
            await Task.yield()
        }
    }

    private func makeGatedModel(
        gate: LoadGate,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { _ in }
    ) -> OverviewViewModel {
        OverviewViewModel(
            load: LoadOverview(snapshots: GatedSnapshots(gate: gate), scans: FakeScans(), actions: FakeActions()),
            sleep: sleep
        )
    }

    @Test func concurrentRefreshesShareOneLoadAndOneSample() async {
        let gate = LoadGate()
        let model = makeGatedModel(gate: gate)
        model.setVisible(true)
        let first = Task { await model.refresh() }
        await gate.waitForEntry()
        let second = Task { await model.refresh() } // e.g. "Scan now" while the loop is loading
        await settle()
        #expect(await gate.entered == 1)
        await gate.open()
        await first.value
        await second.value
        #expect(await gate.entered == 1)
        #expect(model.overview != nil)
        #expect(model.history.count == 1)
    }

    @Test func refreshAfterACompletedOneLoadsAgain() async {
        let gate = LoadGate()
        let model = makeGatedModel(gate: gate)
        model.setVisible(true)
        await gate.open()
        await model.refresh()
        await model.refresh()
        #expect(await gate.entered == 2)
        #expect(model.history.count == 2)
    }

    @Test func refreshJoiningALoadOfACancelledLoopStillPublishesOnce() async {
        let gate = LoadGate()
        let model = makeGatedModel(gate: gate, sleep: { _ in try await Task.sleep(for: .seconds(60)) })
        model.start() // hidden: the first load is held at the gate
        await gate.waitForEntry()
        model.setVisible(true) // restarts the loop; its refresh joins the in-flight load
        await settle()
        await gate.open()
        await settle()
        #expect(await gate.entered == 1)
        #expect(model.overview != nil)
        #expect(model.history.count == 1)
        model.stop()
    }
}
