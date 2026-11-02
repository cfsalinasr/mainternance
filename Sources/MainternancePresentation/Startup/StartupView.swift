import MainternanceDomain
import SwiftUI

/// Renders `StartupViewState`; every rule (what can be switched, what each note says) lives in the state.
public struct StartupView: View {
    private let state: StartupViewState

    public init(state: StartupViewState) {
        self.state = state
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text(StartupText.title).font(.title2.bold())
                Text(StartupText.intro).font(.system(size: 12)).foregroundStyle(.secondary)
                notes
                if state.snapshot == nil, state.isLoading {
                    ProgressView(StartupText.loading)
                }
                if state.showsEmptyState {
                    ContentUnavailableView(StartupText.empty, systemImage: "power")
                }
                ForEach(StartupKind.allCases, id: \.self) { kind in
                    section(kind)
                }
                footer
            }
            .padding(20)
        }
        .task { await state.refresh() }
    }

    private var notes: some View {
        ForEach(state.notes, id: \.self) { line in
            Text(line).font(.system(size: 12)).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func section(_ kind: StartupKind) -> some View {
        let items = state.items(of: kind)
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text(StartupText.sectionTitle(kind)).font(.headline)
                ForEach(items) { row($0) }
            }
        }
    }

    private func row(_ item: StartupItem) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                PreviewListRow(
                    title: item.name, subtitle: state.detail(item), trailing: StartupText.state(item.isEnabled)
                )
                ForEach(state.rowNotes(item), id: \.self) { note in
                    Text(note).font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            if item.isNew {
                // Text badge: new items are never marked by color alone.
                Text(StartupText.newBadge)
                    .font(.system(size: 11, weight: .semibold))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .overlay(Capsule().stroke(.secondary))
                    .accessibilityLabel(StartupText.newBadgeAccessibility)
            }
            Button(StartupText.reveal) { state.reveal(item.id) }
                .accessibilityLabel("Reveal \(item.name) in Finder")
            if state.showsSwitch(item) {
                Toggle(item.name, isOn: Binding(
                    get: { item.isEnabled == true },
                    set: { value in Task { await state.setEnabled(item.id, value) } }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .disabled(state.isBusy(item.id))
                .accessibilityLabel("\(item.name) starts at login")
                .accessibilityHint(StartupText.takesEffect)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .solidCard()
        .accessibilityElement(children: .contain)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(StartupText.loginItemsFooter).font(.system(size: 12)).foregroundStyle(.secondary)
            Button(StartupText.markAllReviewed) { Task { await state.markAllReviewed() } }
                .disabled(!state.canMarkReviewed)
        }
    }
}
