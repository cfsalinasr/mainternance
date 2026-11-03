import MainternanceDomain
import SwiftUI

/// Renders `CleanupViewState`; every rule (what is selected, what can be reviewed, every sentence) lives in the
/// state. Measures when it appears, never at launch: measuring walks the disk.
public struct CleanupView: View {
    private let state: CleanupViewState

    public init(state: CleanupViewState) {
        self.state = state
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text(CleanupText.title).font(.title2.bold())
                Text(CleanupText.intro).font(.system(size: 12)).foregroundStyle(.secondary)
                ForEach(state.notes, id: \.self) { note in
                    Text(note).font(.system(size: 12)).foregroundStyle(.secondary)
                }
                if state.showsMeasuring {
                    ProgressView(CleanupText.measuring)
                }
                if state.showsNothingFound {
                    ContentUnavailableView(CleanupText.nothingFound, systemImage: "sparkles")
                }
                ForEach(state.categories) { card($0) }
                CleanupResultCard(state: state)
                if state.measurement != nil {
                    footer
                }
            }
            .padding(20)
        }
        .task { await state.appear() }
        .sheet(isPresented: Binding(
            get: { state.isReviewing },
            set: {
                if !$0 {
                    state.cancelReview()
                }
            }
        )) {
            CleanupReviewSheet(state: state)
        }
    }

    private func card(_ category: CleanupCategory) -> some View {
        let title = CleanupText.title(category.kind)
        return HStack(spacing: 12) {
            Toggle(isOn: Binding(
                get: { state.isSelected(category: category.kind) },
                set: { _ in state.toggleCategory(category.kind) }
            )) {
                EmptyView()
            }
            .toggleStyle(.checkbox)
            .labelsHidden()
            .disabled(!state.canToggle(category))
            .accessibilityLabel("Include \(title)")
            Image(systemName: CleanupText.symbol(category.kind))
                .frame(width: 22).foregroundStyle(.secondary).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                PreviewListRow(
                    title: title, subtitle: CleanupText.detail(category.kind), trailing: state.sizeText(category)
                )
                if let selection = state.selectionText(category) {
                    Text(selection).font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .solidCard()
        .accessibilityElement(children: .contain)
    }

    private var footer: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(state.selectedText).font(.headline)
                Text(CleanupText.quitAppsNote).font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Spacer()
            if state.isMoving {
                ProgressView(CleanupText.moving).controlSize(.small)
            }
            Button(CleanupText.measureAgain) { Task { await state.measure() } }
                .disabled(!state.canMeasure)
            Button(CleanupText.review) { state.review() }
                .disabled(!state.canReview)
                .keyboardShortcut(.defaultAction)
                .accessibilityHint("Lists what would move to the Trash before anything moves")
        }
        .accessibilityElement(children: .contain)
    }
}

/// What the last move to the Trash really did: moved items and space, then what could not move and why.
struct CleanupResultCard: View {
    let state: CleanupViewState

    var body: some View {
        if state.showsResultCard {
            VStack(alignment: .leading, spacing: 4) {
                if let result = state.resultText {
                    Text(result).font(.system(size: 13, weight: .medium))
                    Text(CleanupText.trashNote).font(.system(size: 12)).foregroundStyle(.secondary)
                }
                if let message = state.message {
                    Text(message).font(.system(size: 12)).foregroundStyle(.secondary)
                }
                ForEach(state.failureLines, id: \.self) { line in
                    Text(line).font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .solidCard()
            .accessibilityElement(children: .combine)
        }
    }
}
