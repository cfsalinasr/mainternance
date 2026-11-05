import MainternanceDomain
import SwiftUI

struct FindingsList: View {
    let model: ScannerViewModel

    var body: some View {
        if !model.findings.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text(ScannerText.findingsHeading(model.findings.count)).font(.headline)
                ForEach(model.findings) { finding in
                    row(finding)
                }
            }
        }
    }

    private func row(_ finding: ScanFinding) -> some View {
        HStack(alignment: .top, spacing: 12) {
            // Shown by icon and text, never color alone.
            Label(ScannerText.detectedBadge, systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.orange)
                .frame(width: 90, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(finding.signature).font(.system(size: 13, weight: .medium))
                Text(ScannerText.shownPath(finding.path))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(ScannerText.shownPath(finding.path))
            }
            Spacer()
            Button(ScannerText.quarantineButton) { model.requestQuarantine(finding.id) }
                .disabled(model.isBusy)
                .accessibilityLabel(ScannerText.quarantineLabel(ScannerText.shownName(finding.path)))
                .accessibilityHint(ScannerText.quarantineHint)
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
            Text(ScannerText.quarantineTitle).font(.title3.bold())
            VStack(alignment: .leading, spacing: 2) {
                Text(ScannerText.shownName(finding.path)).font(.system(size: 13, weight: .medium))
                Text(ScannerText.detectionLine(finding.signature)).font(.system(size: 12)).foregroundStyle(.secondary)
                Text(ScannerText.shownPath(finding.path)).font(.system(size: 12)).foregroundStyle(.secondary)
                    .lineLimit(2).truncationMode(.middle)
            }
            Text(ScannerText.quarantineExplanation)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button(ScannerText.cancelButton, action: cancel).keyboardShortcut(.cancelAction)
                Button(ScannerText.confirmButton, action: confirm).keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}

struct QuarantineSection: View {
    let model: ScannerViewModel

    var body: some View {
        if model.showsQuarantineSection {
            VStack(alignment: .leading, spacing: 8) {
                Text(ScannerText.quarantineHeading).font(.headline)
                if model.quarantineUnreadable {
                    Label(ScannerText.quarantineUnreadable, systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.orange)
                }
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
            Label(ScannerText.quarantinedBadge, systemImage: "lock.fill")
                .font(.system(size: 12, weight: .medium))
                .frame(width: 110, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(ScannerText.shownName(record.originalPath)).font(.system(size: 13, weight: .medium))
                Text(record.signature).font(.system(size: 12)).foregroundStyle(.secondary)
                Text(ScannerText.shownPath(record.originalPath))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(ScannerText.shownPath(record.originalPath))
            }
            Spacer()
            Button(ScannerText.restoreButton) { Task { await model.restore(record.id) } }
                .disabled(model.isBusy)
                .accessibilityLabel(ScannerText.restoreLabel(ScannerText.shownName(record.originalPath)))
                .accessibilityHint(ScannerText.restoreHint)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .solidCard()
        .accessibilityElement(children: .contain)
    }

    private func stuck(_ record: QuarantineRecord) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Label(ScannerText.notMovedBadge, systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.orange)
                .frame(width: 110, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(ScannerText.shownName(record.originalPath)).font(.system(size: 13, weight: .medium))
                Text("\(record.signature): \(ScannerText.notMovedNote)")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                Text(ScannerText.shownPath(record.originalPath))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(ScannerText.shownPath(record.originalPath))
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .solidCard()
        .accessibilityElement(children: .combine)
    }
}
