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

            switch state.segment {
            case .search:
                searchPane(state)
            case .duplicates:
                duplicatesPane(state)
            case .large:
                LargeFilesView(state: state)
            }
        }
        .padding(20)
        .task(id: state.segment) { await state.appear() }
        .onDisappear { state.cancelWork() }
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
                                file: file, quickLook: { state.quickLook(file) }, reveal: { state.reveal(file) }
                            )
                        }
                    }
                }
            }
        }
        .task(id: state.criteria) { await state.searchChanged() }
    }

    private func duplicatesPane(_ state: FilesViewState) -> some View {
        @Bindable var state = state
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text("Keep:").font(.system(size: 13, weight: .medium))
                Picker("Keep", selection: $state.keepRule) {
                    ForEach(KeepRule.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .accessibilityLabel("Keep rule")
            }
            if state.duplicates.isEmpty {
                ContentUnavailableView("No duplicates found", systemImage: "doc.on.doc")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(state.duplicates) { DuplicateGroupView(group: $0, rule: state.keepRule) }
                    }
                }
            }
        }
    }
}
