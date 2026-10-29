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

        /// Orders out the hosting window (never any other window) and reports it hidden right away, because
        /// `orderOut` posts no `willClose` and the occlusion notification may arrive late.
        func dismissHostingWindow() {
            guard let window else { return }
            window.orderOut(nil)
            handle(.willClose)
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
