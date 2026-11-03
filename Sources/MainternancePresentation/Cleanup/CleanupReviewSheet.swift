import MainternanceDomain
import SwiftUI

/// The review step: every category that has entries, with all of its entries (ticked or not), their folder and
/// size; single entries can be ticked or unticked here. Return triggers Cancel; Move to Trash needs an explicit click.
struct CleanupReviewSheet: View {
    let state: CleanupViewState

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(CleanupText.reviewTitle).font(.title3.bold())
            Text(CleanupText.reviewNote).font(.system(size: 13)).foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(state.reviewCategories) { section($0) }
                }
            }
            .frame(maxHeight: 360)
            Divider()
            HStack {
                Text(state.selectedText).font(.headline).monospacedDigit()
                Spacer()
            }
            .accessibilityElement(children: .combine)
            HStack {
                Spacer()
                Button(CleanupText.cancel) { state.cancelReview() }.keyboardShortcut(.defaultAction)
                Button(CleanupText.moveToTrash, role: .destructive) { Task { await state.confirm() } }
                    .disabled(!state.canReview)
                    .accessibilityHint("Moves the ticked items to the Trash, where you can put them back")
            }
        }
        .padding(20)
        .frame(width: 520)
    }

    private func section(_ category: CleanupCategory) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(CleanupText.title(category.kind)).font(.headline)
            ForEach(category.entries) { row($0, kind: category.kind) }
        }
    }

    private func row(_ entry: CleanupEntry, kind: CleanupKind) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Toggle(isOn: Binding(
                get: { state.isSelected(entry: entry.id) },
                set: { _ in state.toggleEntry(entry.id) }
            )) {
                EmptyView()
            }
            .toggleStyle(.checkbox)
            .labelsHidden()
            .disabled(!state.canToggle)
            .accessibilityLabel("Include \(entry.displayName)")
            VStack(alignment: .leading, spacing: 2) {
                PreviewListRow(
                    title: entry.displayName, subtitle: CleanupText.subtitle(entry, kind: kind),
                    trailing: CleanupText.size(entry)
                )
                if let reason = state.failureReason(entry.id) {
                    Text(reason).font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
        }
    }
}
