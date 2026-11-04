import MainternanceDomain
import SwiftUI

/// The review step: every file that would move to the Trash, with its folder and size. Return triggers Cancel;
/// Move to the Trash needs an explicit click.
struct FilesReviewSheet: View {
    let state: FilesViewState

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(FilesText.reviewTitle).font(.title3.bold())
            Text(FilesText.reviewNote).font(.system(size: 13)).foregroundStyle(.secondary)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(state.removableFiles) { file in
                        PreviewListRow(
                            title: file.displayName, subtitle: file.displayPath, trailing: formatFileSize(file.bytes)
                        )
                    }
                }
            }
            .frame(maxHeight: 360)
            Divider()
            Text(FilesText.reviewSummary(count: state.removableFiles.count, bytes: state.reclaimableBytes))
                .font(.headline).monospacedDigit()
            HStack {
                Spacer()
                Button(FilesText.cancel) { state.cancelReview() }.keyboardShortcut(.defaultAction)
                Button(FilesText.trash, role: .destructive) { Task { await state.confirm() } }
                    .disabled(state.removableFiles.isEmpty)
                    .accessibilityHint("Moves these files to the Trash, where you can put them back")
            }
        }
        .padding(20)
        .frame(width: 520)
    }
}
