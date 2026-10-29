import SwiftUI

public struct HomeView: View {
    private let viewModel: OverviewViewModel
    private let navigation: Navigation
    private let scanNow: () -> Void

    public init(viewModel: OverviewViewModel, navigation: Navigation, scanNow: @escaping () -> Void = {}) {
        self.viewModel = viewModel
        self.navigation = navigation
        self.scanNow = scanNow
    }

    public var body: some View {
        if let overview = viewModel.overview {
            content(HomeModel(overview: overview))
        } else {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func content(_ model: HomeModel) -> some View {
        ScrollView {
            VStack(spacing: 12) {
                HealthBanner(banner: model.banner, open: navigation.open, scanNow: scanNow)
                HStack(alignment: .top, spacing: 12) {
                    ForEach(model.tiles) { tile in
                        MetricTile(tile: tile) { navigation.open(tile.destination) }
                    }
                }
                SuggestedActionsCard(actions: model.actions, open: navigation.open)
                ScanSummaryCard(summary: model.scan)
                DetailsDisclosure(
                    series: HistorySeries(history: viewModel.history),
                    temperatureText: model.temperatureText
                )
            }
            .padding(20)
        }
    }
}
