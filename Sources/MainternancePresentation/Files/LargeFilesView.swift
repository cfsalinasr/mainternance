import SwiftUI

struct LargeFilesView: View {
    let state: FilesViewState

    var body: some View {
        VStack(spacing: 12) {
            DiskTreemapView(state: state)
                .frame(height: 220)
            if state.largest.isEmpty {
                ContentUnavailableView("No large files", systemImage: "doc")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(state.largest.sorted { $0.size > $1.size }) { FileResultRow(file: $0) }
                    }
                }
            }
        }
    }
}
