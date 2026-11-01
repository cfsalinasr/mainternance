import MainternanceDomain
import SwiftUI

struct EngineStatusCard: View {
    let model: ScannerViewModel

    private var card: ScannerText.EngineCard {
        ScannerText.engineCard(model.engine, run: model.run)
    }

    private var tint: Color {
        switch model.engine {
        case .ready: .green
        case .updateNeeded, .failed, .homebrewMissing: .orange
        default: .secondary
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: card.symbol)
                .font(.system(size: 22))
                .foregroundStyle(tint)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                Text(card.title).font(.headline)
                Text(card.detail).font(.system(size: 13)).foregroundStyle(.secondary)
                if case let .installing(_, progress) = model.run {
                    progressBar(progress)
                }
            }
            Spacer()
            buttons
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .solidCard()
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private func progressBar(_ progress: Double?) -> some View {
        if let progress {
            ProgressView(value: progress)
                .accessibilityLabel(card.title)
                .accessibilityValue("\(Int((progress * 100).rounded())) percent")
        } else {
            ProgressView().controlSize(.small).accessibilityLabel(card.title)
        }
    }

    private var buttons: some View {
        VStack(alignment: .trailing, spacing: 6) {
            if model.canInstall {
                Button(ScannerText.installButton) { Task { await model.install() } }
                    .accessibilityHint(ScannerText.installHint)
            }
            if model.canUpdateDefinitions {
                Button(ScannerText.updateButton) { Task { await model.updateDefinitions() } }
                    .accessibilityHint(ScannerText.updateHint)
            }
            if showsCheckAgain {
                Button(ScannerText.checkAgainButton) { Task { await model.refreshStatus() } }
            }
        }
    }

    private var showsCheckAgain: Bool {
        guard !model.isBusy else { return false }
        switch model.engine {
        case .homebrewMissing, .failed: return true
        default: return false
        }
    }
}
