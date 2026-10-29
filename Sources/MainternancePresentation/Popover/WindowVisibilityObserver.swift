import AppKit
import SwiftUI

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

        private func report(_ visible: Bool) {
            guard visible != lastReported else { return }
            lastReported = visible
            onChange?(visible)
        }
    }
}
