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
    private let states: WindowStates
    private let visibility: VisibilityCoordinator
    private let popoverDismisser = WindowDismisser()

    init() {
        let composition = CompositionRoot.make()
        let automation = composition.automation
        CompositionRoot.stopScannerOnQuit(composition.scannerServices, automation: automation)
        CompositionRoot.checkScheduleOnWake(automation)
        let model = composition.overview
        model.start()
        viewModel = model
        let settings = composition.settings
        states = WindowStates(
            scanner: composition.scannerModel, settings: settings, startup: composition.startup,
            cleanup: composition.cleanup
        )
        // The loaded values reach the scheduler and the notifier through `settings.onChange`. The scheduler holds
        // the defaults (weekly scan off) until then, so starting it first cannot run a scan the owner turned off.
        Task { await settings.load() }
        automation.start()
        visibility = VisibilityCoordinator(viewModel: model, onHomeVisibilityChange: composition.homeVisibility)
    }

    var body: some Scene {
        MenuBarExtra {
            PopoverHost(viewModel: viewModel, visibility: visibility, dismisser: popoverDismisser)
        } label: {
            MenuBarLabelView(overview: viewModel.overview)
        }
        .menuBarExtraStyle(.window)

        Window("Mainternance", id: "main") {
            MainWindowView(
                navigation: navigation,
                overview: viewModel,
                states: states,
                onVisibilityChange: { visibility.report(.window, visible: $0) },
                onSelectionChange: { visibility.select($0) }
            )
        }
        .defaultLaunchBehavior(.suppressed) // A menu bar app starts with the window closed.
    }
}

/// Lives inside the scene so it can read `openWindow` from the environment.
private struct PopoverHost: View {
    let viewModel: OverviewViewModel
    let visibility: VisibilityCoordinator
    let dismisser: WindowDismisser
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        PopoverView(
            viewModel: viewModel,
            openWindow: {
                openWindow(id: "main")
                NSApp.activate()
            },
            dismisser: dismisser,
            quit: { NSApplication.shared.terminate(nil) },
            onVisibilityChange: { visibility.report(.popover, visible: $0) }
        )
    }
}
