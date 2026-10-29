import SwiftUI

enum ScannerHelp {
    static let engineNotConnected = "Available when the scanner engine is connected"
}

struct EngineStatusCard: View {
    let engine: ScannerEngineState

    private var tint: Color {
        switch engine {
        case .ready: .green
        case .updateNeeded: .orange
        default: .secondary
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: engine.symbol)
                .font(.system(size: 22))
                .foregroundStyle(tint)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                Text(engine.title).font(.headline)
                Text(engine.detail).font(.system(size: 13)).foregroundStyle(.secondary)
                if let progress = engine.progress {
                    ProgressView(value: progress)
                        .accessibilityLabel(engine.title)
                        .accessibilityValue("\(Int((progress * 100).rounded())) percent")
                }
            }
            Spacer()
            if case .notInstalled = engine {
                Button("Install") {
                    // Inert: the scanner engine arrives in a later plan. The button is disabled.
                }
                .disabled(true)
                .help(ScannerHelp.engineNotConnected)
                .accessibilityHint(ScannerHelp.engineNotConnected)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .solidCard()
        .accessibilityElement(children: .contain)
    }
}
