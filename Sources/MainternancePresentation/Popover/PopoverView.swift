import MainternanceDomain
import SwiftUI

public struct PopoverView: View {
    private let viewModel: OverviewViewModel
    private let openWindow: () -> Void
    private let scanNow: () -> Void
    private let onVisibilityChange: @MainActor (Bool) -> Void

    public init(
        viewModel: OverviewViewModel,
        openWindow: @escaping () -> Void,
        scanNow: @escaping () -> Void,
        onVisibilityChange: @escaping @MainActor (Bool) -> Void
    ) {
        self.viewModel = viewModel
        self.openWindow = openWindow
        self.scanNow = scanNow
        self.onVisibilityChange = onVisibilityChange
    }

    public var body: some View {
        GlassPanel {
            VStack(alignment: .leading, spacing: 12) {
                if let overview = viewModel.overview {
                    content(PopoverModel(overview: overview))
                } else {
                    ProgressView().frame(maxWidth: .infinity, minHeight: 120)
                }
            }
            .padding(16)
        }
        .frame(width: 320)
        .background(WindowVisibilityObserver { onVisibilityChange($0) })
    }

    @ViewBuilder
    private func content(_ model: PopoverModel) -> some View {
        hero(model.hero)
        Divider()
        HStack(alignment: .top) {
            ForEach(model.metrics) {
                MetricColumn(title: $0.title, symbol: $0.symbol, value: $0.value, state: $0.state)
            }
        }
        Divider()
        VStack(spacing: 8) {
            ForEach(model.rows) {
                InfoRow(title: $0.title, value: $0.value, symbol: $0.symbol, state: $0.state)
            }
        }
        Divider()
        actionButton("Scan now", symbol: "arrow.clockwise", action: scanNow)
        actionButton("Open Mainternance", symbol: "chevron.right", action: openWindow)
    }

    private func hero(_ hero: PopoverModel.Hero) -> some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text("This Mac").font(.caption).foregroundStyle(.secondary)
                Text(hero.title).font(.system(size: 24, weight: .semibold)).foregroundStyle(hero.state.color)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Image(systemName: hero.symbol)
                    .font(.system(size: 24))
                    .foregroundStyle(hero.state.color)
                if let text = hero.checksText {
                    Text(text).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func actionButton(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(title)
                Spacer()
                Image(systemName: symbol).foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .font(.system(size: 13))
    }
}
