import MainternanceDomain
import MainternancePresentation
import Testing

/// `refresh()` calls that overlap (the loop and a manual refresh) share one load and one history sample.
@MainActor
struct OverviewRefreshCoalescingTests {
    /// Polls observable state with a bound (never a fixed delay) until `condition` holds.
    private func waitUntil(_ condition: () async -> Bool) async {
        for _ in 0 ..< 2000 {
            if await condition() {
                return
            }
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

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
        let second = Task { await model.refresh() } // e.g. a manual refresh while the loop is loading
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
        await waitUntil { model.overview != nil }
        #expect(await gate.entered == 1)
        #expect(model.overview != nil)
        #expect(model.history.count == 1)
        model.stop()
    }

    @Test func activeJoinerClaimsTheResultWhenACancelledJoinerIsFirst() async {
        let gate = LoadGate()
        let model = makeGatedModel(gate: gate)
        model.setVisible(true)
        let starter = Task { await model.refresh() }
        await gate.waitForEntry()
        let cancelledJoiner = Task { await model.refresh() }
        await settle()
        let activeJoiner = Task { await model.refresh() }
        await settle()
        starter.cancel()
        cancelledJoiner.cancel()
        await gate.open()
        await starter.value
        await cancelledJoiner.value
        await activeJoiner.value
        #expect(await gate.entered == 1)
        #expect(model.overview != nil)
        #expect(model.history.count == 1)
    }

    @Test func nothingIsPublishedWhenEveryCallerWasCancelled() async {
        let gate = LoadGate()
        let model = makeGatedModel(gate: gate)
        model.setVisible(true)
        let starter = Task { await model.refresh() }
        await gate.waitForEntry()
        let joiner = Task { await model.refresh() }
        await settle()
        starter.cancel()
        joiner.cancel()
        await gate.open()
        await starter.value
        await joiner.value
        #expect(model.overview == nil)
        #expect(model.history.isEmpty)
    }

    @Test func aSingleActiveCallerPublishesOnce() async {
        let gate = LoadGate()
        let model = makeGatedModel(gate: gate)
        model.setVisible(true)
        await gate.open()
        await model.refresh()
        #expect(model.overview != nil)
        #expect(model.history.count == 1)
    }
}
