import SwiftUI

struct MetricTile: View {
    let tile: HomeModel.Tile
    let action: () -> Void

    var body: some View {
        if tile.isLink {
            Button(action: action) { content.contentShape(Rectangle()) }
                .buttonStyle(.plain)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(label)
        } else {
            content
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(label)
        }
    }

    private var label: String {
        "\(tile.title), \(tile.value)\(tile.caption.map { ", \($0)" } ?? "")\(tile.state.accessibilityNote)"
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(tile.title, systemImage: tile.symbol)
                .font(.system(size: 12))
                .foregroundStyle(tile.state.color)
            Text(tile.value)
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(tile.state == .good ? Color.primary : tile.state.color)
            if let caption = tile.caption {
                Text(caption).font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .solidCard()
    }
}
