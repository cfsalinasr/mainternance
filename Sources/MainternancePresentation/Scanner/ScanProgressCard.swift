import SwiftUI

/// Shown only while a scan runs: how many files were scanned and which folder the engine is in.
struct ScanProgressCard: View {
    let model: ScannerViewModel

    var body: some View {
        if case let .scanning(scanned, current) = model.run {
            HStack(alignment: .top, spacing: 12) {
                ProgressView().controlSize(.small).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(ScannerText.scanning).font(.headline)
                    Text("\(ScannerText.files(scanned)) scanned").font(.system(size: 13)).foregroundStyle(.secondary)
                    if !current.isEmpty {
                        Text(ScannerText.shownPath(current))
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(ScannerText.shownPath(current))
                    }
                }
                Spacer()
                Button(ScannerText.cancelButton) { Task { await model.cancel() } }
                    .accessibilityLabel(ScannerText.cancelScanLabel)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .solidCard()
            .accessibilityElement(children: .contain)
            .accessibilityLabel(spokenLabel(scanned: scanned, current: current))
        }
    }

    private func spokenLabel(scanned: Int, current: String) -> String {
        let place = current.isEmpty ? "" : ", in \(ScannerText.shownPath(current))"
        return "Scanning, \(ScannerText.files(scanned)) scanned\(place)"
    }
}
