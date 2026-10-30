import AppKit
import SwiftUI

/// Why this exists: a `MenuBarExtra(.window)` keeps its content view alive after the first open, so
/// `onAppear`/`onDisappear` do not track open/close. The hosting NSWindow's state does.
struct WindowVisibilityObserver: NSViewRepresentable {
    var onChange: @MainActor (Bool) -> Void
    /// When set, it is pointed at the observed window so the owner can dismiss exactly that window.
    var dismisser: WindowDismisser?

    func makeNSView(context _: Context) -> VisibilityView {
        let view = VisibilityView()
        view.onChange = onChange
        dismisser?.view = view
        return view
    }

    func updateNSView(_ view: VisibilityView, context _: Context) {
        view.onChange = onChange
        dismisser?.view = view
    }

    @MainActor
    final class VisibilityView: NSView {
        var onChange: (@MainActor (Bool) -> Void)?
        private var state = WindowVisibilityState()
        private var lastReported: Bool?
        /// Counts `didBecomeKey` events; a change since a fallback was scheduled means the user reopened.
        private var reopenCount = 0

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            // Removal on window change is required: the observer re-registers for each new window.
            // swiftlint:disable:next notification_center_detachment
            NotificationCenter.default.removeObserver(self)
            guard let window else {
                handle(.detached)
                return
            }
            let center = NotificationCenter.default
            center.addObserver(
                self,
                selector: #selector(occlusionChanged),
                name: NSWindow.didChangeOcclusionStateNotification,
                object: window
            )
            center.addObserver(
                self,
                selector: #selector(becameKey),
                name: NSWindow.didBecomeKeyNotification,
                object: window
            )
            center.addObserver(
                self,
                selector: #selector(resignedKey),
                name: NSWindow.didResignKeyNotification,
                object: window
            )
            center.addObserver(
                self,
                selector: #selector(willClose),
                name: NSWindow.willCloseNotification,
                object: window
            )
            handle(.attached)
        }

        /// Selector-based observers are removed here without touching main-actor state.
        nonisolated deinit {
            NotificationCenter.default.removeObserver(self)
        }

        @objc private func occlusionChanged() {
            handle(.occlusionChanged)
        }

        @objc private func becameKey() {
            reopenCount += 1
            handle(.becameKey)
        }

        @objc private func resignedKey() {
            handle(.resignedKey)
        }

        @objc private func willClose() {
            handle(.willClose)
        }

        private func handle(_ event: WindowVisibilityState.Event) {
            let facts = window.map {
                WindowFacts(
                    isOrderedIn: $0.isVisible,
                    occlusionVisible: $0.occlusionState.contains(.visible),
                    isKey: $0.isKeyWindow
                )
            }
            report(state.handle(event, window: facts))
        }

        /// Dismisses the popover only if it is currently shown (never toggles a hidden one open). Preferred
        /// path: click the status item like a user would, so `MenuBarExtra` resets its own presented state
        /// and the button highlight. Fallback: order out this view's own window, either at once when no
        /// button is found or after a one-shot check when the click did not close it. The hidden state is
        /// reported at once (idempotent with the notifications that follow, `report` drops repeats).
        /// Not verified at runtime: the button lookup and the click's effect can only be checked by hand.
        func dismissHostingWindow() {
            guard let window, window.isVisible else { return }
            if let button = StatusItemButtonFinder.find(in: NSApp.windows) {
                button.performClick(nil)
                scheduleFallbackCheck(for: window)
            } else {
                window.orderOut(nil)
            }
            handle(.dismissed)
        }

        /// A single delayed check (not polling): if the click left the popover on screen, order out that
        /// same window and keep the reported state hidden. A reopen in the meantime (a `didBecomeKey`) cancels it.
        /// Runtime behavior of this cancel is unverified. It never touches any other window.
        private func scheduleFallbackCheck(for popover: NSWindow) {
            let scheduledAt = reopenCount
            Task { @MainActor [weak self, weak popover] in
                try? await Task.sleep(for: .milliseconds(300))
                guard let self, let popover,
                      PopoverDismissFallback.afterClick(
                          stillOrderedIn: popover.isVisible,
                          isPopoverWindow: window === popover,
                          reopened: reopenCount != scheduledAt
                      ) == .orderOut
                else { return }
                popover.orderOut(nil)
                handle(.dismissed)
            }
        }

        private func report(_ visible: Bool) {
            guard visible != lastReported else { return }
            lastReported = visible
            onChange?(visible)
        }
    }
}

/// Lets the owner of a `MenuBarExtra(.window)` popover dismiss it: that content stays open until a click
/// outside, so choosing "Open Mainternance" must close it itself. It only ever touches the window that
/// hosts the observed view, so the main window cannot be closed by mistake.
@MainActor
public final class WindowDismisser {
    weak var view: WindowVisibilityObserver.VisibilityView?

    public init() {
        // Nothing to set up: the observer view registers itself once it is in a window.
    }

    public func dismiss() {
        view?.dismissHostingWindow()
    }
}

/// Finds this app's menu bar extra button. It relies on the status-bar window's class name containing
/// `StatusBarWindow`, a non-public AppKit class (the button class `NSStatusBarButton` is public). That is
/// not a stable contract and was not verified at runtime by tests, which is why the caller falls back to
/// ordering out the popover's own window when nothing is found or the click does not close it.
/// This app has exactly one status item, so the first match is unambiguous.
@MainActor
enum StatusItemButtonFinder {
    static func find(in windows: [NSWindow]) -> NSStatusBarButton? {
        for window in windows where String(describing: type(of: window)).contains("StatusBarWindow") {
            if let content = window.contentView, let button = button(in: content) {
                return button
            }
        }
        return nil
    }

    private static func button(in view: NSView) -> NSStatusBarButton? {
        if let button = view as? NSStatusBarButton {
            return button
        }
        for subview in view.subviews {
            if let found = button(in: subview) {
                return found
            }
        }
        return nil
    }
}
