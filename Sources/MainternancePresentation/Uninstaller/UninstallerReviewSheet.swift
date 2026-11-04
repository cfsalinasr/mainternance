import MainternanceDomain
import SwiftUI

/// The review step: the app (when ticked) and every ticked leftover with its size. Return triggers Cancel; Confirm
/// needs an explicit click.
struct UninstallerReviewSheet: View {
    let state: UninstallerViewState

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(UninstallerText.reviewTitle).font(.title3.bold())
            Text(UninstallerText.reviewNote).font(.system(size: 13)).foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    if state.includesApp, let details = state.details {
                        PreviewListRow(
                            title: UninstallerText.appTitle(details.app),
                            subtitle: UninstallerText.appPath(details.app),
                            trailing: UninstallerText.size(details)
                        )
                    }
                    ForEach(state.selectedLeftovers) { leftover in
                        PreviewListRow(
                            title: leftover.displayName, subtitle: UninstallerText.subtitle(leftover),
                            trailing: UninstallerText.size(leftover)
                        )
                    }
                }
            }
            .frame(maxHeight: 360)
            Divider()
            Text(state.selectedText).font(.headline).monospacedDigit()
            HStack {
                Spacer()
                Button(UninstallerText.cancel) { state.cancelReview() }.keyboardShortcut(.defaultAction)
                Button(UninstallerText.confirm, role: .destructive) { Task { await state.confirm() } }
                    .disabled(!state.canReview)
                    .accessibilityHint("Moves the listed items to the Trash, where you can put them back")
            }
        }
        .padding(20)
        .frame(width: 520)
    }
}
