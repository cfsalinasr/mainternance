import SwiftUI

struct FindingsList: View {
    let state: ScannerViewState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Findings (sample)").font(.headline)
            ForEach(state.findings) { finding in
                row(finding)
            }
        }
    }

    private func severityColor(_ severity: FindingSeverity) -> Color {
        switch severity {
        case .low: .secondary
        case .medium: .orange
        case .high: .red
        }
    }

    private func row(_ finding: ScanFinding) -> some View {
        let isQuarantined = state.isQuarantined(finding.id)
        return HStack(alignment: .top, spacing: 12) {
            // Severity is shown by icon and text, never color alone.
            Label(finding.severity.title, systemImage: finding.severity.symbol)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(severityColor(finding.severity))
                .frame(width: 90, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(finding.name).font(.system(size: 13, weight: .medium))
                Text(finding.reason).font(.system(size: 12)).foregroundStyle(.secondary)
                Text(finding.path)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(finding.path)
            }
            Spacer()
            if isQuarantined {
                Label("Marked quarantined (sample)", systemImage: "lock.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Button("Restore") { state.restore(finding.id) }
                    .accessibilityLabel("Restore \(finding.name)")
                    .accessibilityHint("Clears the sample quarantine mark; no file is touched")
            } else {
                Button("Quarantine") { state.requestQuarantine(finding.id) }
                    .accessibilityLabel("Quarantine \(finding.name)")
                    .accessibilityHint("Asks for confirmation first")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .solidCard()
        .accessibilityElement(children: .contain)
    }
}

struct QuarantineConfirmation: View {
    let finding: ScanFinding
    let confirm: () -> Void
    let cancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Quarantine this file?").font(.title3.bold())
            VStack(alignment: .leading, spacing: 2) {
                Text(finding.name).font(.system(size: 13, weight: .medium))
                Text(finding.path).font(.system(size: 12)).foregroundStyle(.secondary)
                    .lineLimit(2).truncationMode(.middle)
            }
            Text(
                [
                    "Sample only: once the scanner engine is connected, this file would be moved to quarantine",
                    "and could be restored. For now nothing is moved or deleted."
                ].joined(separator: " ")
            )
            .font(.system(size: 13))
            .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel", action: cancel).keyboardShortcut(.cancelAction)
                Button("Quarantine", action: confirm).keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}
