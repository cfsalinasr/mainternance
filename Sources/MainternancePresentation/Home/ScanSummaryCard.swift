import SwiftUI

struct ScanSummaryCard: View {
    let summary: HomeModel.ScanSummary

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: summary.symbol).foregroundStyle(summary.state.color)
            Text(summary.last)
            Spacer()
            Text(summary.next).foregroundStyle(.secondary)
        }
        .font(.system(size: 13))
        .frame(maxWidth: .infinity)
        .solidCard()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(summary.last). \(summary.next)\(summary.state.accessibilityNote)")
    }
}
