import MainternanceDomain
import SwiftUI

public struct ScannerView: View {
    private let model: ScannerViewModel

    public init(model: ScannerViewModel) {
        self.model = model
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                EngineStatusCard(model: model)
                scanButtons
                messages
                ScanProgressCard(model: model)
                ScanResultCard(model: model)
                FindingsList(model: model)
                QuarantineSection(model: model)
                Text(ScannerText.caption).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            .padding(20)
        }
        .task { await model.refreshStatus() }
        .sheet(item: Binding(
            get: { model.pendingQuarantine },
            set: {
                if $0 == nil {
                    model.cancelQuarantine()
                }
            }
        )) { finding in
            QuarantineConfirmation(
                finding: finding,
                confirm: { Task { await model.confirmQuarantine() } },
                cancel: { model.cancelQuarantine() }
            )
        }
    }

    private var scanButtons: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Button(ScannerText.quickButton) { Task { await model.startScan(.quick) } }
                    .accessibilityHint(ScannerText.quickScope)
                Button(ScannerText.fullButton) { Task { await model.startScan(.full) } }
                    .accessibilityHint(ScannerText.fullScope)
                Spacer()
            }
            .disabled(!model.canStartScan)
            Text(ScannerText.quickScope).font(.system(size: 12)).foregroundStyle(.secondary)
            Text("\(ScannerText.fullScope) \(ScannerText.cloudAdvisory)")
                .font(.system(size: 12)).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var messages: some View {
        if model.isQuarantining {
            Label(ScannerText.checkingFile, systemImage: "hourglass")
                .font(.system(size: 13))
        }
        if model.savedResultsUnreadable {
            Label(ScannerText.savedResultsUnreadable, systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 13))
                .foregroundStyle(.orange)
        }
        if model.scanDidNotFinish, !model.run.isWorking {
            Label(ScannerText.lastScanDidNotFinish, systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 13))
                .foregroundStyle(.orange)
        }
        if model.unattributedFromIncompleteScan > 0 {
            Label(
                ScannerText.unattributedIncomplete(model.unattributedFromIncompleteScan),
                systemImage: "exclamationmark.triangle.fill"
            )
            .font(.system(size: 13))
            .foregroundStyle(.orange)
        }
        if let error = model.errorMessage {
            Label(error, systemImage: "exclamationmark.octagon.fill")
                .font(.system(size: 13))
                .foregroundStyle(.red)
                .textSelection(.enabled)
        }
        if let notice = model.notice {
            Label(notice, systemImage: "info.circle")
                .font(.system(size: 13))
                .textSelection(.enabled)
        }
    }
}
