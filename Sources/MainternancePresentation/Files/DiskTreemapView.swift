import SwiftUI

struct DiskTreemapView: View {
    let state: FilesViewState

    /// Neutral dark blue/purple/slate fills (no green, amber or red) so white labels always reach strong contrast.
    private static let palette: [Color] = [
        Color(hue: 0.60, saturation: 0.55, brightness: 0.45),
        Color(hue: 0.72, saturation: 0.45, brightness: 0.48),
        Color(hue: 0.56, saturation: 0.40, brightness: 0.42),
        Color(hue: 0.78, saturation: 0.40, brightness: 0.46),
        Color(hue: 0.62, saturation: 0.15, brightness: 0.42)
    ]

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
                            guard let child = node.children.first(where: { $0.id == tile.id }),
                                  let rect = tile.drawRect() else { continue }
                            context.fill(
                                Path(roundedRect: rect, cornerRadius: 4),
                                with: .color(Self.palette[index % Self.palette.count])
                            )
                            if rect.width > 70, rect.height > 34 {
                                let label = "\(child.name)\n\(formatFileSize(child.size))"
                                context.drawLayer { layer in
                                    layer.clip(to: Path(rect.insetBy(dx: 4, dy: 4)))
                                    layer.draw(
                                        Text(label).font(.caption).foregroundColor(.white),
                                        at: CGPoint(x: rect.minX + 6, y: rect.minY + 6), anchor: .topLeading
                                    )
                                }
                            }
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { location in
                        if let hit = tiles.first(where: { $0.drawRect()?.contains(location) == true }) {
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
            openButtons(node)
        }
    }

    /// Keyboard and VoiceOver route into folders; the Canvas itself is a single read-only element.
    @ViewBuilder
    private func openButtons(_ node: TreemapNode) -> some View {
        let folders = node.children.filter { !$0.children.isEmpty && $0.size > 0 }
        if !folders.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(folders) { folder in
                        Button { state.drillInto(folder.id) } label: {
                            Label(folder.name, systemImage: "folder")
                        }
                        .controlSize(.small)
                        .accessibilityLabel("Open \(folder.name)")
                    }
                }
            }
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
