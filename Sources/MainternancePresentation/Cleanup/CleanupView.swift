import SwiftUI

public struct CleanupView: View {
    private let state: CleanupViewState

    public init(state: CleanupViewState) {
        self.state = state
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Cleanup").font(.title2.bold())
                if state.categories.isEmpty {
                    ContentUnavailableView("Nothing to clean", systemImage: "sparkles")
                } else {
                    ForEach(state.categories) { row($0) }
                    footer
                }
            }
            .padding(20)
        }
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

    private func row(_ category: CleanupCategory) -> some View {
        let cleaned = state.isCleaned(category.id)
        return HStack(spacing: 12) {
            Toggle(isOn: Binding(get: { state.isSelected(category.id) }, set: { _ in state.toggle(category.id) })) {
                EmptyView()
            }
            .toggleStyle(.checkbox)
            .labelsHidden()
            .disabled(cleaned)
            .accessibilityLabel("Include \(category.name)")
            .accessibilityHint(cleaned ? "Marked as cleaned in this sample; nothing was moved" :
                "Adds or removes this category from the total")
            Image(systemName: category.symbol).frame(width: 22).foregroundStyle(.secondary).accessibilityHidden(true)
            PreviewListRow(
                title: category.name,
                subtitle: category.detail,
                trailing: cleaned ? "Marked cleaned (sample)" : formatBytes(category.bytes)
            )
            if cleaned {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).accessibilityHidden(true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .solidCard()
        .accessibilityElement(children: .contain)
    }

    private var footer: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Selected: \(formatBytes(state.selectedBytes))").font(.headline)
                if state.cleanedBytes > 0 {
                    Text("Marked cleaned (sample): \(formatBytes(state.cleanedBytes))").font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                Text("Sample only: nothing is moved to the Trash").font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Review") { state.review() }
                .disabled(!state.canReview)
                .keyboardShortcut(.defaultAction)
                .accessibilityHint(state
                    .canReview ? "Shows what would move to the Trash" : "Select at least one category")
        }
        .accessibilityElement(children: .contain)
    }
}

struct CleanupReviewSheet: View {
    let state: CleanupViewState

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Move to the Trash?").font(.title3.bold())
            Text("These categories would move to the Trash. You can restore them from there.")
                .font(.system(size: 13)).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 8) {
                ForEach(state.reviewItems) { PreviewListRow(
                    title: $0.name,
                    subtitle: $0.detail,
                    trailing: formatBytes($0.bytes)
                ) }
            }
            Divider()
            HStack {
                Text("Total").font(.headline)
                Spacer()
                Text(formatBytes(state.selectedBytes)).font(.headline).monospacedDigit()
            }
            .accessibilityElement(children: .combine)
            HStack {
                Spacer()
                // Safety: Return triggers Cancel; Move to Trash must be an explicit click.
                Button("Cancel") { state.cancelReview() }.keyboardShortcut(.defaultAction)
                Button("Move to Trash", role: .destructive) { state.confirmReview() }
                    .accessibilityHint("Marks the listed categories as cleaned in this preview")
            }
        }
        .padding(20)
        .frame(width: 440)
    }
}
