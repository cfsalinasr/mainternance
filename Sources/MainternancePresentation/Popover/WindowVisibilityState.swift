/// What the hosting window looks like at the moment a notification arrives.
public struct WindowFacts: Equatable, Sendable {
    /// `NSWindow.isVisible`: the window is ordered in.
    public var isOrderedIn: Bool
    /// `NSWindow.occlusionState.contains(.visible)`.
    public var occlusionVisible: Bool
    public var isKey: Bool

    public init(isOrderedIn: Bool, occlusionVisible: Bool, isKey: Bool) {
        self.isOrderedIn = isOrderedIn
        self.occlusionVisible = occlusionVisible
        self.isKey = isKey
    }
}

/// Pure state behind `WindowVisibilityObserver`. Closing a window fires `willClose` and then
/// `didResignKey` while the occlusion state can still say "visible"; so once closed, the window
/// stays hidden until it becomes key again or the view moves to a (new) window.
public struct WindowVisibilityState: Equatable, Sendable {
    public enum Event: Equatable, Sendable {
        case attached, detached, becameKey, resignedKey, occlusionChanged, willClose
        /// The owner dismissed the window itself; hidden until it becomes key again or is re-attached.
        case dismissed
    }

    public private(set) var isClosed = false

    public init() {}

    /// Applies one event and returns the visibility to report; `window` is nil once detached.
    public mutating func handle(_ event: Event, window: WindowFacts?) -> Bool {
        switch event {
        case .attached, .becameKey, .detached:
            isClosed = false
        case .willClose, .dismissed:
            isClosed = true
        case .resignedKey, .occlusionChanged:
            break
        }
        guard event != .detached, let window else { return false }
        return Self.isVisible(window, isClosed: isClosed)
    }

    /// A closed or ordered-out window is hidden; otherwise visible if on screen or key.
    public static func isVisible(_ window: WindowFacts, isClosed: Bool) -> Bool {
        !isClosed && window.isOrderedIn && (window.occlusionVisible || window.isKey)
    }
}

/// What to do once the status item was clicked to dismiss the popover and the click has had time to act.
public enum PopoverDismissFallback: Equatable, Sendable {
    /// The popover closed; nothing to do.
    case none
    /// The click did not close it: order the popover's own window out so it cannot overlap the main window.
    case orderOut

    /// One-shot check after the click. `stillOrderedIn` is the popover window's `isVisible` at that moment;
    /// `isPopoverWindow` is whether the observed window is still the one the click was meant to dismiss;
    /// `reopened` is whether a `didBecomeKey` arrived since the check was scheduled. A legitimate reopen
    /// (`MenuBarExtra` reuses the same window) must not be closed again, or `MenuBarExtra`'s own presented
    /// state would go out of sync. Not verified at runtime: the event order is inferred from AppKit docs.
    public static func afterClick(stillOrderedIn: Bool, isPopoverWindow: Bool = true, reopened: Bool = false) -> Self {
        isPopoverWindow && stillOrderedIn && !reopened ? .orderOut : .none
    }
}
