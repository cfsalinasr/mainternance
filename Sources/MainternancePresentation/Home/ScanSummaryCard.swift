import SwiftUI

struct ScanSummaryCard: View {
    let summary: HomeModel.ScanSummary

    private var label: String {
        let spoken = [summary.last, summary.next].compactMap(\.self).joined(separator: ". ")
        return "\(spoken)\(summary.state.accessibilityNote)"
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: summary.symbol).foregroundStyle(summary.state.color)
            Text(summary.last)
            Spacer()
            if let next = summary.next {
                Text(next).foregroundStyle(.secondary)
            }
        }
        .font(.system(size: 13))
        .frame(maxWidth: .infinity)
        .solidCard()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
    }
}
