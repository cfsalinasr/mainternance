import SwiftUI

struct DiskTreemapView: View {
    let state: FilesViewState

    private static let palette: [Color] = [.blue, .teal, .indigo, .orange, .purple, .green, .pink, .cyan]

    var body: some View {
        let node = state.currentNode
        VStack(alignment: .leading, spacing: 6) {
            breadcrumb
            GeometryReader { proxy in
                let bounds = CGRect(origin: .zero, size: proxy.size)
                let tiles = TreemapLayout.layout(
                    node.children.map { TreemapItem(id: $0.id, size: $0.size) }, in: bounds
                )
                if tiles.isEmpty {
                    ContentUnavailableView("Nothing to show", systemImage: "square.dashed")
                } else {
                    Canvas { context, _ in
                        for (index, tile) in tiles.enumerated() {
                            guard let child = node.children.first(where: { $0.id == tile.id }) else { continue }
                            let rect = tile.rect.insetBy(dx: 1, dy: 1)
                            context.fill(
                                Path(roundedRect: rect, cornerRadius: 4),
                                with: .color(Self.palette[index % Self.palette.count].opacity(0.75))
                            )
                            if rect.width > 70, rect.height > 34 {
                                let label = "\(child.name)\n\(formatFileSize(child.size))"
                                context.draw(
                                    Text(label).font(.caption).foregroundColor(.white),
                                    at: CGPoint(x: rect.minX + 6, y: rect.minY + 6), anchor: .topLeading
                                )
                            }
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { location in
                        if let hit = tiles.first(where: { $0.rect.contains(location) }) {
                            state.drillInto(hit.id)
                        }
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Disk usage treemap for \(node.name)")
                    .accessibilityValue(
                        node.children.filter { $0.size > 0 }
                            .map { "\($0.name) \(formatFileSize($0.size))" }.joined(separator: ", ")
                    )
                }
            }
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }

    private var breadcrumb: some View {
        HStack(spacing: 4) {
            Button { state.goUp() } label: { Image(systemName: "chevron.left") }
                .buttonStyle(.borderless)
                .disabled(state.drillPath.isEmpty)
                .accessibilityLabel("Back")
            ForEach(Array(state.breadcrumb.enumerated()), id: \.element.id) { depth, node in
                if depth > 0 {
                    Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.secondary)
                }
                Button(node.name) { state.jump(toDepth: depth) }
                    .buttonStyle(.borderless)
                    .fontWeight(depth == state.breadcrumb.count - 1 ? .semibold : .regular)
            }
            Spacer()
            Text(formatFileSize(state.currentNode.size)).font(.caption).foregroundStyle(.secondary)
        }
        .font(.system(size: 12))
    }
}
