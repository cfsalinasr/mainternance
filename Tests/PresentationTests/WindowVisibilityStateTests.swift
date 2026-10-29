import MainternancePresentation
import Testing

struct WindowVisibilityStateTests {
    private typealias Step = (event: WindowVisibilityState.Event, window: WindowFacts?)

    private func facts(orderedIn: Bool = true, occlusion: Bool, key: Bool) -> WindowFacts {
        WindowFacts(isOrderedIn: orderedIn, occlusionVisible: occlusion, isKey: key)
    }

    /// Feeds the events to a fresh state and returns what each one reported, plus the final state.
    private func run(_ steps: [Step]) -> (reported: [Bool], state: WindowVisibilityState) {
        var state = WindowVisibilityState()
        let reported = steps.map { state.handle($0.event, window: $0.window) }
        return (reported, state)
    }

    /// Ported from the former `WindowVisibility.isVisible` tests (window ordered in).
    @Test func visibilityDecision() {
        #expect(WindowVisibilityState.isVisible(facts(occlusion: true, key: false), isClosed: false))
        #expect(WindowVisibilityState.isVisible(facts(occlusion: false, key: true), isClosed: false))
        #expect(!WindowVisibilityState.isVisible(facts(occlusion: false, key: false), isClosed: false))
        #expect(!WindowVisibilityState.isVisible(facts(occlusion: true, key: true), isClosed: true))
    }

    @Test func orderedOutWindowIsHiddenEvenIfOcclusionSaysVisible() {
        #expect(!WindowVisibilityState.isVisible(facts(orderedIn: false, occlusion: true, key: true), isClosed: false))
    }

    @Test func closeThenResignKeyStaysHiddenWhileOcclusionStillVisible() {
        // The red button: willClose, then didResignKey before the window is ordered out.
        let result = run([
            (.attached, facts(occlusion: true, key: true)),
            (.willClose, facts(occlusion: true, key: true)),
            (.resignedKey, facts(occlusion: true, key: false)),
            (.occlusionChanged, facts(occlusion: true, key: false))
        ])
        #expect(result.reported == [true, false, false, false])
        #expect(result.state.isClosed)
    }

    @Test func reopenedWindowBecomingKeyIsVisibleAgain() {
        let result = run([
            (.attached, facts(occlusion: true, key: true)),
            (.willClose, facts(occlusion: true, key: true)),
            (.resignedKey, facts(occlusion: true, key: false)),
            (.occlusionChanged, facts(orderedIn: false, occlusion: false, key: false)),
            (.becameKey, facts(occlusion: true, key: true))
        ])
        #expect(result.reported == [true, false, false, false, true])
        #expect(!result.state.isClosed)
    }

    @Test func attachingToANewWindowClearsClosed() {
        let result = run([
            (.willClose, facts(occlusion: true, key: false)),
            (.attached, facts(occlusion: true, key: false))
        ])
        #expect(result.reported == [false, true])
    }

    @Test func detachedIsHidden() {
        let result = run([
            (.attached, facts(occlusion: true, key: true)),
            (.detached, nil),
            (.occlusionChanged, nil)
        ])
        #expect(result.reported == [true, false, false])
    }

    @Test func occlusionAndKeyChangesTrackAnOpenWindow() {
        let result = run([
            (.attached, facts(occlusion: false, key: false)),
            (.occlusionChanged, facts(occlusion: true, key: false)),
            (.resignedKey, facts(occlusion: true, key: false)),
            (.occlusionChanged, facts(occlusion: false, key: false))
        ])
        #expect(result.reported == [false, true, true, false])
    }
}

extension WindowVisibilityStateTests {
    @Test func dismissedPopoverReportsHiddenUntilKeyAgain() {
        var state = WindowVisibilityState()
        let shown = WindowFacts(isOrderedIn: true, occlusionVisible: true, isKey: true)
        let orderedOut = WindowFacts(isOrderedIn: false, occlusionVisible: true, isKey: false)
        let first = state.handle(.becameKey, window: shown)
        // The dismiss path: orderOut then willClose, while occlusion can still say visible.
        let afterDismiss = state.handle(.willClose, window: orderedOut)
        let lateOcclusion = state.handle(.occlusionChanged, window: shown)
        let reopened = state.handle(.becameKey, window: shown)
        #expect(first)
        #expect(!afterDismiss)
        #expect(!lateOcclusion)
        #expect(reopened)
    }
}
