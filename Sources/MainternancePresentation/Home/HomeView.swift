import SwiftUI

public struct HomeView: View {
    private let viewModel: OverviewViewModel
    private let navigation: Navigation

    public init(viewModel: OverviewViewModel, navigation: Navigation) {
        self.viewModel = viewModel
        self.navigation = navigation
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
                HealthBanner(banner: model.banner, open: navigation.open)
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
