import MainternanceDomain
import SwiftUI

/// One group of identical files: how many copies, what moving the extra ones frees, and for each copy whether the
/// keep rule keeps it or would move it. The rule lives in the state.
struct DuplicateGroupView: View {
    let group: DuplicateGroup
    let state: FilesViewState

    var body: some View {
        let selection = state.selection(for: group)
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(FilesText.copies(group.files.count, each: group.bytesEach), systemImage: "doc.on.doc")
                    .font(.headline)
                Spacer()
                Text(FilesText.frees(group.reclaimableBytes)).font(.caption).foregroundStyle(.secondary)
            }
            ForEach(group.files) { file in
                FileResultRow(
                    file: file, quickLook: { state.quickLook(file) }, reveal: { state.reveal(file) },
                    badge: selection.isKept(file) ? FilesText.keep : FilesText.wouldRemove,
                    note: state.failureReason(for: file)
                )
                .opacity(selection.isKept(file) ? 1 : 0.75)
            }
        }
        .accessibilityElement(children: .contain)
    }
}
