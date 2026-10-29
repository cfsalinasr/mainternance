import AppKit
import SwiftUI

/// Pure decision used by the observer: a closed window is hidden; otherwise visible if on screen or key.
public enum WindowVisibility {
    public static func isVisible(occlusionVisible: Bool, isKey: Bool, isClosed: Bool) -> Bool {
        !isClosed && (occlusionVisible || isKey)
    }
}

/// Why this exists: a `MenuBarExtra(.window)` keeps its content view alive after the first open, so
/// `onAppear`/`onDisappear` do not track open/close. The hosting NSWindow's state does.
struct WindowVisibilityObserver: NSViewRepresentable {
    var onChange: @MainActor (Bool) -> Void

    func makeNSView(context _: Context) -> VisibilityView {
        let view = VisibilityView()
        view.onChange = onChange
        return view
    }

    func updateNSView(_ view: VisibilityView, context _: Context) {
        view.onChange = onChange
    }

    @MainActor
    final class VisibilityView: NSView {
        var onChange: (@MainActor (Bool) -> Void)?
        private var isClosed = false
        private var lastReported: Bool?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            NotificationCenter.default.removeObserver(self)
            guard let window else {
                report(false)
                return
            }
            isClosed = false
            let center = NotificationCenter.default
            center.addObserver(
                self,
                selector: #selector(refresh),
                name: NSWindow.didChangeOcclusionStateNotification,
                object: window
            )
            center.addObserver(
                self,
                selector: #selector(refresh),
                name: NSWindow.didBecomeKeyNotification,
                object: window
            )
            center.addObserver(
                self,
                selector: #selector(refresh),
                name: NSWindow.didResignKeyNotification,
                object: window
            )
            center.addObserver(self, selector: #selector(closed), name: NSWindow.willCloseNotification, object: window)
            evaluate()
        }

        /// Selector-based observers are removed here without touching main-actor state.
        nonisolated deinit {
            NotificationCenter.default.removeObserver(self)
        }

        @objc private func refresh() {
            isClosed = false
            evaluate()
        }

        @objc private func closed() {
            isClosed = true
            evaluate()
        }

        private func evaluate() {
            guard let window else { return }
            report(WindowVisibility.isVisible(
                occlusionVisible: window.occlusionState.contains(.visible),
                isKey: window.isKeyWindow,
                isClosed: isClosed
            ))
        }

        private func report(_ visible: Bool) {
            guard visible != lastReported else { return }
            lastReported = visible
            onChange?(visible)
        }
    }
}
