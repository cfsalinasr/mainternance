import SwiftUI

struct MetricTile: View {
    let tile: HomeModel.Tile
    let action: () -> Void

    var body: some View {
        Button(action: action) {
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
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            "\(tile.title), \(tile.value)\(tile.caption.map { ", \($0)" } ?? "")\(tile.state.accessibilityNote)"
        )
    }
}
