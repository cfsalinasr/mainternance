import AppKit
import MainternancePresentation
import SwiftUI

@main
struct MainternanceApp: App {
    // Ownership lives here as plain `let`s on purpose: `@State` does not compile with the Command Line
    // Tools-only toolchain (its SwiftUI macro plugin is missing), and the `App` value is created once for
    // the whole process lifetime, so these references are stable. Do not move them into a View or Scene
    // body (or any struct SwiftUI recreates): each re-evaluation would build fresh models and lose state.
    private let viewModel: OverviewViewModel
    private let navigation = Navigation()
    private let states = WindowStates()
    private let visibility: VisibilityCoordinator

    init() {
        let model = CompositionRoot.makeOverviewViewModel()
        model.start()
        viewModel = model
        visibility = VisibilityCoordinator(viewModel: model)
    }

    var body: some Scene {
        MenuBarExtra {
            PopoverHost(viewModel: viewModel, visibility: visibility)
        } label: {
            MenuBarLabelView(overview: viewModel.overview)
        }
        .menuBarExtraStyle(.window)

        Window("Mainternance", id: "main") {
            MainWindowView(
                navigation: navigation,
                overview: viewModel,
                states: states,
                scanNow: { viewModel.scanNow() },
                onVisibilityChange: { visibility.report(.window, visible: $0) }
            )
        }
        .defaultLaunchBehavior(.suppressed) // A menu bar app starts with the window closed.
    }
}

/// Lives inside the scene so it can read `openWindow` from the environment.
private struct PopoverHost: View {
    let viewModel: OverviewViewModel
    let visibility: VisibilityCoordinator
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        PopoverView(
            viewModel: viewModel,
            openWindow: {
                openWindow(id: "main")
                NSApp.activate()
            },
            scanNow: { viewModel.scanNow() },
            onVisibilityChange: { visibility.report(.popover, visible: $0) }
        )
    }
}
