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
    }

    public private(set) var isClosed = false

    public init() {}

    /// Applies one event and returns the visibility to report; `window` is nil once detached.
    public mutating func handle(_ event: Event, window: WindowFacts?) -> Bool {
        switch event {
        case .attached, .becameKey, .detached:
            isClosed = false
        case .willClose:
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
