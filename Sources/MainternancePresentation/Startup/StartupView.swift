import SwiftUI

public struct StartupView: View {
    private let state: StartupViewState

    public init(state: StartupViewState) {
        self.state = state
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Startup").font(.title2.bold())
                if state.items.isEmpty {
                    ContentUnavailableView("No startup items", systemImage: "power")
                }
                ForEach(StartupKind.allCases) { kind in
                    section(kind)
                }
            }
            .padding(20)
        }
    }

    @ViewBuilder
    private func section(_ kind: StartupKind) -> some View {
        let items = state.items(of: kind)
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text(kind.title).font(.headline)
                ForEach(items) { row($0) }
            }
        }
    }

    private func row(_ item: StartupItem) -> some View {
        HStack(spacing: 12) {
            PreviewListRow(title: item.name, subtitle: item.detail, trailing: item.isEnabled ? "On" : "Off")
            if item.isNew {
                // Text badge: new items are never marked by color alone.
                Text("New")
                    .font(.system(size: 11, weight: .semibold))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .overlay(Capsule().stroke(.secondary))
                    .accessibilityLabel("New since last review")
            }
            Button("Reveal in Finder") {
                // Inert: the system engine arrives in a later plan; the button is disabled.
            }
            .disabled(true)
            .help(SystemHelp.engineNotConnected)
            .accessibilityLabel("Reveal \(item.name) in Finder")
            .accessibilityHint(SystemHelp.engineNotConnected)
            Toggle(item.name, isOn: Binding(get: { item.isEnabled }, set: { _ in state.toggle(item.id) }))
                .labelsHidden()
                .toggleStyle(.switch)
                .accessibilityLabel("\(item.name) enabled")
                .accessibilityHint("Preview only; changes nothing on your Mac")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .solidCard()
        .accessibilityElement(children: .contain)
    }
}
