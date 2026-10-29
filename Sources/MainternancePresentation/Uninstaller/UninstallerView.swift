import SwiftUI

public struct UninstallerView: View {
    private let state: UninstallerViewState

    public init(state: UninstallerViewState) {
        self.state = state
    }

    public var body: some View {
        if state.apps.isEmpty {
            ContentUnavailableView("No apps found", systemImage: "trash")
        } else {
            HStack(alignment: .top, spacing: 0) {
                list.frame(width: 240)
                Divider()
                detail.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
    }

    private var list: some View {
        List(selection: Binding(get: { state.selectedID }, set: { state.select($0) })) {
            ForEach(state.apps) { app in
                PreviewListRow(
                    title: app.name,
                    trailing: formatBytes(app.totalBytes),
                    isSelected: state.selectedID == app.id
                )
                .tag(app.id)
            }
        }
        .accessibilityLabel("Installed apps")
    }

    @ViewBuilder
    private var detail: some View {
        if let app = state.selectedApp {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text(app.name).font(.title2.bold())
                    Text("Preview of the leftover files that would be removed with this app.")
                        .font(.system(size: 13)).foregroundStyle(.secondary)
                    if app.leftovers.isEmpty {
                        Text("No leftovers found").foregroundStyle(.secondary)
                    }
                    ForEach(app.leftovers) { leftover in
                        PreviewListRow(
                            title: leftover.displayName,
                            subtitle: leftover.path,
                            trailing: formatBytes(leftover.bytes)
                        )
                        .solidCard()
                    }
                    HStack {
                        Text("Total: \(formatBytes(app.totalBytes))").font(.headline)
                        Spacer()
                        Button("Move to Trash") {
                            // Inert: the system engine arrives in a later plan; the button is disabled.
                        }
                        .disabled(true)
                        .help(SystemHelp.engineNotConnected)
                        .accessibilityLabel("Move \(app.name) and its leftovers to the Trash")
                        .accessibilityHint(SystemHelp.engineNotConnected)
                    }
                }
                .padding(20)
            }
        } else {
            ContentUnavailableView(
                "Select an app",
                systemImage: "trash",
                description: Text("Pick an app to preview its leftovers.")
            )
        }
    }
}
