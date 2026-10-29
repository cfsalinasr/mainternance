import MainternancePresentation
import SwiftUI

@main
struct MainternanceApp: App {
    /// A plain stored reference: the SwiftUI macros behind @State are unavailable with Command Line Tools only.
    private let viewModel: OverviewViewModel

    init() {
        let model = CompositionRoot.makeOverviewViewModel()
        model.start()
        viewModel = model
    }

    var body: some Scene {
        MenuBarExtra {
            PopoverView(
                viewModel: viewModel,
                openWindow: {}, // Wired to the app window in Task 8.
                scanNow: { Task { await viewModel.refresh() } }
            )
        } label: {
            let label = MenuBarLabel.make(from: viewModel.overview)
            Image(systemName: label.symbol)
                .foregroundStyle(label.state.color)
            Text(label.text)
        }
        .menuBarExtraStyle(.window)
    }
}
