import SwiftUI

struct FileSearchBar: View {
    let state: FilesViewState

    var body: some View {
        @Bindable var state = state
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary).accessibilityHidden(true)
                TextField("Search by name or path", text: $state.criteria.text)
                    .textFieldStyle(.plain)
                    .accessibilityLabel("Search files")
                if !state.criteria.text.isEmpty {
                    Button { state.criteria.text = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear search")
                }
            }
            .padding(8)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10, style: .continuous))

            Menu {
                Picker("Type", selection: $state.criteria.kind) {
                    Text("Any type").tag(FileKind?.none)
                    ForEach(FileKind.allCases) { Label($0.title, systemImage: $0.symbol).tag(FileKind?.some($0)) }
                }
            } label: {
                Label(state.criteria.kind?.title ?? "Type", systemImage: "square.grid.2x2")
            }
            .accessibilityLabel("Filter by type")

            Menu {
                Picker("Size", selection: $state.criteria.size) {
                    ForEach(SizeFilter.allCases) { Text($0.title).tag($0) }
                }
            } label: {
                Label(state.criteria.size == .any ? "Size" : state.criteria.size.title, systemImage: "scalemass")
            }
            .accessibilityLabel("Filter by size")

            Menu {
                Picker("Date", selection: $state.criteria.date) {
                    ForEach(DateFilter.allCases) { Text($0.title).tag($0) }
                }
            } label: {
                Label(state.criteria.date == .any ? "Date" : state.criteria.date.title, systemImage: "calendar")
            }
            .accessibilityLabel("Filter by date")
        }
        .menuStyle(.button)
        .fixedSize(horizontal: false, vertical: true)
    }
}
