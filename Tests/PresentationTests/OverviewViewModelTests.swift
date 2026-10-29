import Foundation
import MainternanceDomain
import MainternancePresentation
import Synchronization
import Testing

@MainActor
struct OverviewViewModelTests {
    private func makeModel(
        sleeper: FakeSleeper,
        counter: CallCounter,
        lowPower: @escaping @Sendable () -> Bool = { false }
    ) -> OverviewViewModel {
        OverviewViewModel(
            load: LoadOverview(snapshots: FakeSnapshots(counter: counter), scans: FakeScans(), actions: FakeActions()),
            isLowPowerMode: lowPower,
            sleep: { try await sleeper.sleep($0) }
        )
    }

    /// Gives a (buggy) runaway loop ample chances to run; the loop is cancelled in correct code.
    private func settle() async {
        for _ in 0 ..< 50 {
            await Task.yield()
        }
    }

    @Test func refreshSetsOverview() async {
        let counter = CallCounter()
        let model = makeModel(sleeper: FakeSleeper(), counter: counter)
        #expect(model.overview == nil)
        await model.refresh()
        #expect(model.overview != nil)
        #expect(counter.count == 1)
    }

    @Test func visibleLoopSleepsTwoSeconds() async {
        let sleeper = FakeSleeper()
        let model = makeModel(sleeper: sleeper, counter: CallCounter())
        model.setVisible(true)
        model.start()
        await sleeper.waitForSleeps(1)
        #expect(await sleeper.durations == [.seconds(2)])
        #expect(model.overview != nil)
        model.stop()
    }

    @Test func hiddenLoopSleepsFortyFiveSeconds() async {
        let sleeper = FakeSleeper()
        let model = makeModel(sleeper: sleeper, counter: CallCounter())
        model.setVisible(false)
        model.start()
        await sleeper.waitForSleeps(1)
        #expect(await sleeper.durations == [.seconds(45)])
        model.stop()
    }

    @Test func defaultVisibilityIsHidden() async {
        let sleeper = FakeSleeper()
        let model = makeModel(sleeper: sleeper, counter: CallCounter())
        model.start()
        await sleeper.waitForSleeps(1)
        #expect(await sleeper.durations == [.seconds(45)])
        model.stop()
    }

    @Test func lowPowerDoublesVisibleInterval() async {
        let sleeper = FakeSleeper()
        let model = makeModel(sleeper: sleeper, counter: CallCounter(), lowPower: { true })
        model.setVisible(true)
        model.start()
        await sleeper.waitForSleeps(1)
        #expect(await sleeper.durations == [.seconds(4)])
        model.stop()
    }

    @Test func lowPowerIsReadEachCycle() async {
        let sleeper = FakeSleeper()
        let flag = Mutex(false)
        let model = makeModel(sleeper: sleeper, counter: CallCounter(), lowPower: { flag.withLock { $0 } })
        model.setVisible(true)
        model.start()
        await sleeper.waitForSleeps(1)
        flag.withLock { $0 = true }
        await sleeper.releaseAll()
        await sleeper.waitForSleeps(2)
        #expect(await sleeper.durations == [.seconds(2), .seconds(4)])
        model.stop()
    }

    @Test func visibilityChangeWakesLoopAndRefreshesImmediately() async {
        let sleeper = FakeSleeper()
        let counter = CallCounter()
        let model = makeModel(sleeper: sleeper, counter: counter)
        model.start()
        await sleeper.waitForSleeps(1)
        #expect(counter.count == 1)

        model.setVisible(true)
        await sleeper.waitForSleeps(2)
        #expect(await sleeper.durations == [.seconds(45), .seconds(2)])
        #expect(counter.count == 2)

        // The cancelled 45 s sleep must not leave a second loop behind.
        await sleeper.releaseAll()
        await sleeper.waitForSleeps(3)
        await settle()
        #expect(await sleeper.durations.count == 3)
        #expect(counter.count == 3)
        model.stop()
    }

    @Test func noRefreshAfterStopEvenIfSleepIsReleased() async {
        // The fake ignores cancellation, so only the loop's own guard can prevent a refresh.
        let sleeper = FakeSleeper(honorsCancellation: false)
        let counter = CallCounter()
        let model = makeModel(sleeper: sleeper, counter: counter)
        model.setVisible(true)
        model.start()
        await sleeper.waitForSleeps(1)
        #expect(counter.count == 1)

        model.stop()
        await sleeper.releaseAll()
        await settle()
        #expect(counter.count == 1)
        #expect(await sleeper.durations.count == 1)
    }

    @Test func noRefreshAfterStopWithCancellableSleep() async {
        let sleeper = FakeSleeper()
        let counter = CallCounter()
        let model = makeModel(sleeper: sleeper, counter: counter)
        model.setVisible(true)
        model.start()
        await sleeper.waitForSleeps(1)
        model.stop()
        await sleeper.releaseAll()
        await settle()
        #expect(counter.count == 1)
        #expect(await sleeper.durations.count == 1)
    }

    @Test func startTwiceCreatesOneLoop() async {
        let sleeper = FakeSleeper()
        let counter = CallCounter()
        let model = makeModel(sleeper: sleeper, counter: counter)
        model.start()
        await sleeper.waitForSleeps(1)
        // A second start while the first loop is already sleeping must not add a loop.
        model.start()
        await settle()
        #expect(counter.count == 1)
        #expect(await sleeper.durations.count == 1)
        model.stop()
    }

    @Test func hidingDoesNotRefreshAndSleepsFortyFiveSeconds() async {
        let sleeper = FakeSleeper()
        let counter = CallCounter()
        let model = makeModel(sleeper: sleeper, counter: counter)
        model.setVisible(true)
        model.start()
        await sleeper.waitForSleeps(1)
        #expect(counter.count == 1)

        model.setVisible(false)
        await sleeper.waitForSleeps(2)
        await settle()
        #expect(await sleeper.durations == [.seconds(2), .seconds(45)])
        #expect(counter.count == 1)
        model.stop()
    }

    @Test func refreshInFlightWhenStoppedDoesNotAssign() async {
        let gate = LoadGate()
        let model = OverviewViewModel(
            load: LoadOverview(snapshots: GatedSnapshots(gate: gate), scans: FakeScans(), actions: FakeActions()),
            sleep: { _ in }
        )
        model.setVisible(true)
        model.start()
        await gate.waitForEntry()
        model.stop()
        await gate.open()
        await settle()
        #expect(model.overview == nil)
        #expect(model.history.isEmpty)
    }

    @Test func refreshInFlightWhenVisibilityChangesDoesNotAssignStaleResult() async {
        let gate = LoadGate()
        let model = OverviewViewModel(
            load: LoadOverview(snapshots: GatedSnapshots(gate: gate), scans: FakeScans(), actions: FakeActions()),
            sleep: { _ in try await Task.sleep(for: .seconds(60)) }
        )
        model.setVisible(true)
        model.start()
        await gate.waitForEntry()
        model.setVisible(false) // restarts the loop; the in-flight load belongs to the cancelled one
        await gate.open()
        await settle()
        #expect(model.overview == nil)
        model.stop()
    }

    @Test func modelIsReleasedWhileLoopSleeps() async {
        let sleeper = FakeSleeper()
        var model: OverviewViewModel? = makeModel(sleeper: sleeper, counter: CallCounter())
        weak var weakModel = model
        model?.start()
        await sleeper.waitForSleeps(1)
        model = nil
        #expect(weakModel == nil)
    }

    @Test func historyAppendsWhileVisible() async {
        let model = makeModel(sleeper: FakeSleeper(), counter: CallCounter())
        model.setVisible(true)
        await model.refresh()
        await model.refresh()
        #expect(model.history.count == 2)
        #expect(model.history.last?.cpu == 0.1)
        #expect(model.history.last?.gpu == nil)
        #expect(model.history.last?.memoryPressure == .normal)
    }

    @Test func historyIsNotAppendedWhileHidden() async {
        let model = makeModel(sleeper: FakeSleeper(), counter: CallCounter())
        await model.refresh()
        #expect(model.overview != nil)
        #expect(model.history.isEmpty)
    }

    @Test func historyIsCappedAtThirty() async {
        let model = makeModel(sleeper: FakeSleeper(), counter: CallCounter())
        model.setVisible(true)
        for _ in 0 ..< 35 {
            await model.refresh()
        }
        #expect(model.history.count == 30)
    }

    @Test func canRestartAfterStop() async {
        let sleeper = FakeSleeper()
        let counter = CallCounter()
        let model = makeModel(sleeper: sleeper, counter: counter)
        model.start()
        await sleeper.waitForSleeps(1)
        model.stop()
        model.start()
        await sleeper.waitForSleeps(2)
        #expect(counter.count == 2)
        model.stop()
    }
}
