import MainternanceDomain
import SwiftUI

public struct MainWindowView: View {
    private let navigation: Navigation
    private let overview: OverviewViewModel
    private let scanNow: () -> Void
    private let onVisibilityChange: @MainActor (Bool) -> Void
    private let states: WindowStates

    public init(
        navigation: Navigation,
        overview: OverviewViewModel,
        states: WindowStates,
        scanNow: @escaping () -> Void = {},
        onVisibilityChange: @escaping @MainActor (Bool) -> Void = { _ in }
    ) {
        self.navigation = navigation
        self.overview = overview
        self.states = states
        self.scanNow = scanNow
        self.onVisibilityChange = onVisibilityChange
    }

    public var body: some View {
        NavigationSplitView {
            SidebarView(navigation: navigation)
        } detail: {
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.background)
        }
        .frame(minWidth: 760, minHeight: 520)
        .background(WindowVisibilityObserver { onVisibilityChange($0) })
    }

    @ViewBuilder
    private var detail: some View {
        switch navigation.selection {
        case .home:
            HomeView(viewModel: overview, navigation: navigation, scanNow: scanNow)
        case .files:
            FilesView(navigation: navigation, state: states.files)
        case .scanner:
            ScannerView(state: states.scanner)
        case .cleanup:
            CleanupView(state: states.cleanup)
        case .startup:
            StartupView(state: states.startup)
        case .uninstaller:
            UninstallerView(state: states.uninstaller)
        case .settings:
            SettingsView(state: states.settings)
        }
    }
}
