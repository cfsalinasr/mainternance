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
            SampleDataBadge()
            Picker("Section", selection: $state.segment) {
                ForEach(FilesSegment.allCases) { Text($0.title).tag($0) }
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
    }

    private func searchPane(_ state: FilesViewState) -> some View {
        let results = state.results
        return VStack(spacing: 12) {
            FileSearchBar(state: state)
            if results.isEmpty {
                ContentUnavailableView.search(text: state.criteria.text)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(results) { FileResultRow(file: $0) }
                    }
                }
            }
        }
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
