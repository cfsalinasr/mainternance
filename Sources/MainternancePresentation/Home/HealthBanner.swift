import MainternanceDomain
import SwiftUI

/// Chrome-level status banner: glass tinted by the overall state.
struct HealthBanner: View {
    let banner: HomeModel.Banner
    let open: (AppDestination) -> Void

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: banner.symbol)
                .font(.system(size: 28))
                .foregroundStyle(banner.state.color)
            VStack(alignment: .leading, spacing: 3) {
                Text(banner.title).font(.system(size: 16, weight: .semibold))
                reasons
            }
            Spacer()
            Button("Scan now") {
                // Inert: the scanner engine arrives in a later plan; the button is disabled.
            }
            .buttonStyle(.glass)
            .disabled(true)
            .help(ScannerHelp.engineNotConnected)
            .accessibilityHint(ScannerHelp.engineNotConnected)
        }
        .padding(16)
        .glassEffect(
            .regular.tint(banner.state.color.opacity(0.22)),
            in: RoundedRectangle(cornerRadius: 18, style: .continuous)
        )
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var reasons: some View {
        if banner.reasons.isEmpty {
            Text(banner.goodText).font(.system(size: 13)).foregroundStyle(.secondary)
        } else {
            WrapLayout(spacing: 4) {
                ForEach(Array(banner.reasons.enumerated()), id: \.element.id) { index, reason in
                    HStack(spacing: 4) {
                        if index > 0 {
                            Text("·").foregroundStyle(.secondary)
                        }
                        if reason.isLink {
                            Button(reason.text) { open(reason.destination) }
                                .buttonStyle(.plain)
                                .foregroundStyle(.secondary)
                                .accessibilityHint("Opens the related section")
                        } else {
                            Text(reason.text).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .font(.system(size: 13))
        }
    }
}

/// Left-to-right layout that wraps to new lines, so many reasons never overflow the banner.
struct WrapLayout: Layout {
    var spacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache _: inout ()) -> CGSize {
        arrange(width: proposal.width ?? .infinity, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal _: ProposedViewSize, subviews: Subviews, cache _: inout ()) {
        let result = arrange(width: bounds.width, subviews: subviews)
        for (subview, origin) in zip(subviews, result.origins) {
            subview.place(at: CGPoint(x: bounds.minX + origin.x, y: bounds.minY + origin.y), proposal: .unspecified)
        }
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> (size: CGSize, origins: [CGPoint]) {
        var origins: [CGPoint] = []
        var originX: CGFloat = 0
        var originY: CGFloat = 0
        var rowHeight: CGFloat = 0
        var maxX: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if originX > 0, originX + size.width > width {
                originX = 0
                originY += rowHeight + spacing
                rowHeight = 0
            }
            origins.append(CGPoint(x: originX, y: originY))
            originX += size.width + spacing
            maxX = max(maxX, originX - spacing)
            rowHeight = max(rowHeight, size.height)
        }
        return (CGSize(width: maxX, height: originY + rowHeight), origins)
    }
}
