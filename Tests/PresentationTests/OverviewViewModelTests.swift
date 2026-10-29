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
        model.start()
        await sleeper.waitForSleeps(1)
        await settle()
        #expect(counter.count == 1)
        #expect(await sleeper.durations.count == 1)
        model.stop()
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
