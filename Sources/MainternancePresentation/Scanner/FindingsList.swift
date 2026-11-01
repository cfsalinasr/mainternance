import MainternanceDomain
import SwiftUI

struct FindingsList: View {
    let model: ScannerViewModel

    var body: some View {
        if !model.findings.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Findings (\(model.findings.count))").font(.headline)
                ForEach(model.findings) { finding in
                    row(finding)
                }
            }
        }
    }

    private func row(_ finding: ScanFinding) -> some View {
        HStack(alignment: .top, spacing: 12) {
            // Shown by icon and text, never color alone.
            Label("Detected", systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.orange)
                .frame(width: 90, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(finding.signature).font(.system(size: 13, weight: .medium))
                Text(finding.path)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(finding.path)
            }
            Spacer()
            Button("Quarantine…") { model.requestQuarantine(finding.id) }
                .disabled(model.isBusy)
                .accessibilityLabel("Quarantine \((finding.path as NSString).lastPathComponent)")
                .accessibilityHint("Asks for confirmation first")
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
                Text((finding.path as NSString).lastPathComponent).font(.system(size: 13, weight: .medium))
                Text("Detection: \(finding.signature)").font(.system(size: 12)).foregroundStyle(.secondary)
                Text(finding.path).font(.system(size: 12)).foregroundStyle(.secondary)
                    .lineLimit(2).truncationMode(.middle)
            }
            Text(ScannerText.quarantineExplanation)
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

struct QuarantineSection: View {
    let model: ScannerViewModel

    var body: some View {
        if !model.quarantined.isEmpty || !model.notMoved.isEmpty || model.unclaimedCount > 0 {
            VStack(alignment: .leading, spacing: 8) {
                Text("Quarantine").font(.headline)
                ForEach(model.quarantined) { record in
                    contained(record)
                }
                ForEach(model.notMoved) { record in
                    stuck(record)
                }
                if model.unclaimedCount > 0 {
                    Text(ScannerText.unclaimed(model.unclaimedCount))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func contained(_ record: QuarantineRecord) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Label("Quarantined", systemImage: "lock.fill")
                .font(.system(size: 12, weight: .medium))
                .frame(width: 110, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text((record.originalPath as NSString).lastPathComponent).font(.system(size: 13, weight: .medium))
                Text(record.signature).font(.system(size: 12)).foregroundStyle(.secondary)
                Text(record.originalPath)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(record.originalPath)
            }
            Spacer()
            Button("Restore") { Task { await model.restore(record.id) } }
                .disabled(model.isBusy)
                .accessibilityLabel("Restore \((record.originalPath as NSString).lastPathComponent)")
                .accessibilityHint("Puts the file back where it came from")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .solidCard()
        .accessibilityElement(children: .contain)
    }

    private func stuck(_ record: QuarantineRecord) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Label("Not moved", systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.orange)
                .frame(width: 110, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text((record.originalPath as NSString).lastPathComponent).font(.system(size: 13, weight: .medium))
                Text("\(record.signature): \(ScannerText.notMovedNote)")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                Text(record.originalPath)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(record.originalPath)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .solidCard()
        .accessibilityElement(children: .combine)
    }
}
