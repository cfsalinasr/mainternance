import SwiftUI

struct ScanProgressCard: View {
    let run: ScanRunState

    var body: some View {
        switch run {
        case .idle:
            EmptyView()
        case let .running(scanned, current):
            HStack(alignment: .top, spacing: 12) {
                ProgressView().controlSize(.small).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(run.title).font(.headline)
                    Text(run.detail).font(.system(size: 13)).foregroundStyle(.secondary)
                    Text(current)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(current)
                }
                Spacer()
                Button("Cancel") {}
                    .disabled(true)
                    .help(ScannerHelp.engineNotConnected)
                    .accessibilityLabel("Cancel scan")
                    .accessibilityHint(ScannerHelp.engineNotConnected)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .solidCard()
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Scanning, \(max(scanned, 0)) files scanned, in \(current)")
        case let .finished(findings):
            HStack(spacing: 12) {
                Image(systemName: findings == 0 ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(findings == 0 ? Color.green : Color.orange)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(run.title).font(.headline)
                    Text(run.detail).font(.system(size: 13)).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .solidCard()
            .accessibilityElement(children: .combine)
        }
    }
}
