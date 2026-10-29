import AppKit
import MainternancePresentation
import SwiftUI

@main
struct MainternanceApp: App {
    /// Plain stored references: the SwiftUI macros behind @State are unavailable with Command Line Tools only.
    private let viewModel: OverviewViewModel
    private let navigation = Navigation()
    private let filesState = FilesViewState()
    private let scannerState = ScannerViewState()
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
            let label = MenuBarLabel.make(from: viewModel.overview)
            Image(systemName: label.symbol)
                .foregroundStyle(label.state.color)
            Text(label.text)
        }
        .menuBarExtraStyle(.window)

        Window("Mainternance", id: "main") {
            MainWindowView(
                navigation: navigation,
                overview: viewModel,
                filesState: filesState,
                scannerState: scannerState,
                scanNow: { Task { await viewModel.refresh() } }, // Real scanning arrives in a later plan.
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
            scanNow: { Task { await viewModel.refresh() } },
            onVisibilityChange: { visibility.report(.popover, visible: $0) }
        )
    }
}
