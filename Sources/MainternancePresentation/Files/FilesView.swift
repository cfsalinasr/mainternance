import MainternanceDomain
import SwiftUI

public struct FilesView: View {
    private let navigation: Navigation
    private let state: FilesViewState

    public init(navigation: Navigation, state: FilesViewState) {
        self.navigation = navigation
        self.state = state
    }

    public var body: some View {
        @Bindable var state = state
        VStack(alignment: .leading, spacing: 12) {
            Picker("Section", selection: $state.segment) {
                ForEach(FilesSegment.shown) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .accessibilityLabel("Files section")

            FilesResultCard(state: state)

            switch state.segment {
            case .search:
                searchPane(state)
            case .duplicates:
                DuplicatesView(state: state)
            case .large:
                LargeFilesView(state: state)
            }
        }
        .padding(20)
        .task(id: state.segment) { await state.appear() }
        .onDisappear { state.cancelWork() }
        .sheet(isPresented: Binding(
            get: { state.isReviewing },
            set: {
                if !$0 {
                    state.cancelReview()
                }
            }
        )) {
            FilesReviewSheet(state: state)
        }
    }

    private func searchPane(_ state: FilesViewState) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            FileSearchBar(state: state)
            Text(FilesText.spotlightNote).font(.system(size: 12)).foregroundStyle(.secondary)
            if state.isSearching {
                ProgressView(FilesText.searching).controlSize(.small)
            }
            if let note = state.searchTruncatedText {
                Text(note).font(.system(size: 12)).foregroundStyle(.secondary)
            }
            if let status = state.searchStatusText {
                ContentUnavailableView(status, systemImage: "magnifyingglass")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(state.searchResults) { file in
                            FileResultRow(
                                file: file, quickLook: { state.quickLook(file) }, reveal: { state.reveal(file) },
                                trash: { state.requestTrash(file) }, canTrash: !state.isBusy,
                                note: state.failureReason(for: file)
                            )
                        }
                    }
                }
            }
        }
        .task(id: state.criteria) { await state.searchChanged() }
    }
}

/// What the last move to the Trash really did: moved files and space, then each file that could not move and why.
struct FilesResultCard: View {
    let state: FilesViewState

    var body: some View {
        if let result = state.resultText {
            VStack(alignment: .leading, spacing: 4) {
                Text(result).font(.system(size: 13, weight: .medium))
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
