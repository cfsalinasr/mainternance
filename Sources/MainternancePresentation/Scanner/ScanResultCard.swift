import MainternanceDomain
import SwiftUI

/// What the last finished scan says, in plain facts, and the Full Disk Access help when macOS denied access.
struct ScanResultCard: View {
    let model: ScannerViewModel

    var body: some View {
        if case let .finished(summary) = model.run {
            let report = ScannerText.report(summary)
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 12) {
                    // The state is the icon AND the title text, never color alone.
                    Image(systemName: report.symbol)
                        .font(.system(size: 22))
                        .foregroundStyle(report.isCleanAndComplete ? Color.green : Color.orange)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(report.title).font(.headline)
                        ForEach(Array(report.lines.enumerated()), id: \.offset) { _, line in
                            Text(line).font(.system(size: 13)).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                }
                if model.needsFullDiskAccess {
                    fullDiskAccessHelp
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .solidCard()
            .accessibilityElement(children: .contain)
        }
    }

    private var fullDiskAccessHelp: some View {
        VStack(alignment: .leading, spacing: 6) {
            Divider()
            Text(ScannerText.permissionExplanation(model.permissionDeniedCount, folders: model.permissionDeniedFolders))
                .font(.system(size: 13))
            Button(ScannerText.fullDiskAccessButton) { model.openFullDiskAccessSettings() }
                .accessibilityHint(ScannerText.fullDiskAccessHint)
        }
    }
}
