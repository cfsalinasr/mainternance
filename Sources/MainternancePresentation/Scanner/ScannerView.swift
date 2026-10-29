import SwiftUI

public struct ScannerView: View {
    private let state: ScannerViewState

    public init(state: ScannerViewState) {
        self.state = state
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                EngineStatusCard(engine: state.engine)
                scanButtons
                ScanProgressCard(run: state.run)
                results
                Text(state.scheduleSummary())
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Scheduled scan: \(state.scheduleSummary())")
                designPreview
            }
            .padding(20)
        }
        .sheet(item: Binding(
            get: { state.pendingFinding },
            set: {
                if $0 == nil {
                    state.cancelQuarantine()
                }
            }
        )) { finding in
            QuarantineConfirmation(
                finding: finding,
                confirm: { state.confirmQuarantine() },
                cancel: { state.cancelQuarantine() }
            )
        }
    }

    private var scanButtons: some View {
        HStack {
            // The actions have no backend yet; enabled buttons simply do nothing.
            Button("Quick scan") {
                // Inert: the scanner engine arrives in a later plan.
            }
            .accessibilityHint(state.engine.canScan ? "" : ScannerHelp.engineNotConnected)
            Button("Full scan") {
                // Inert: the scanner engine arrives in a later plan.
            }
            .accessibilityHint(state.engine.canScan ? "" : ScannerHelp.engineNotConnected)
            Spacer()
        }
        .disabled(!state.engine.canScan)
        .help(state.engine.canScan ? "" : ScannerHelp.engineNotConnected)
    }

    @ViewBuilder
    private var results: some View {
        switch state.resultsContent {
        case .clean:
            ContentUnavailableView(
                "No threats found",
                systemImage: "checkmark.shield",
                description: Text("Your Mac looks clean.")
            )
        case .findings:
            FindingsList(state: state)
        case .none:
            EmptyView()
        }
    }

    /// Design preview: removed in the scanner-engine plan, once real engine and run states exist.
    private var designPreview: some View {
        VStack(alignment: .leading, spacing: 6) {
            Divider()
            Text("Design preview").font(.headline)
            Picker("Sample state", selection: Binding(
                get: { state.previewID },
                set: { state.select(previewID: $0) }
            )) {
                ForEach(ScannerPreview.all) { Text($0.title).tag($0.id) }
            }
            .accessibilityLabel("Design preview sample state")
            .accessibilityHint("Shows sample data for review; not a real scan")
        }
    }
}
