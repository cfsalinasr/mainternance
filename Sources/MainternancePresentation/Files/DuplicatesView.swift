import MainternanceDomain
import SwiftUI

/// The Duplicates tab: a Scan button with what the scan is doing, the keep rule, the review button and the groups.
/// Rules live in the state.
struct DuplicatesView: View {
    let state: FilesViewState

    var body: some View {
        @Bindable var state = state
        return VStack(alignment: .leading, spacing: 12) {
            Text(FilesText.duplicatesIntro).font(.system(size: 12)).foregroundStyle(.secondary)
            controls
            ForEach(state.duplicateNotes, id: \.self) { note in
                Text(note).font(.system(size: 12)).foregroundStyle(.secondary)
            }
            if !state.duplicateGroups.isEmpty {
                Text(state.duplicatesTotalText).font(.system(size: 12)).foregroundStyle(.secondary)
            }
            rulePicker
            groups
        }
    }

    private var controls: some View {
        HStack(spacing: 10) {
            if state.isFindingDuplicates {
                Button(FilesText.stop) { state.stopDuplicateScan() }
                ProgressView().controlSize(.small)
                if let phase = state.duplicatePhase {
                    Text(phase).font(.system(size: 12)).foregroundStyle(.secondary)
                }
            } else {
                Button(state.hasFoundDuplicates ? FilesText.scanAgain : FilesText.scan) {
                    state.startDuplicateScan()
                }
                .disabled(!state.canStartDuplicateScan)
            }
            Spacer()
        }
    }

    private var rulePicker: some View {
        @Bindable var state = state
        return HStack(spacing: 8) {
            Text(FilesText.keepLabel).font(.system(size: 13, weight: .medium))
            Picker("Keep", selection: $state.keepRule) {
                ForEach(KeepRule.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .disabled(!state.canChangeKeepRule)
            .accessibilityLabel("Keep rule")
            Spacer()
            if let text = state.reviewButtonText {
                Button(text) { state.review() }.disabled(!state.canReview)
            }
        }
    }

    @ViewBuilder private var groups: some View {
        if state.duplicateGroups.isEmpty {
            if state.isFindingDuplicates {
                Spacer()
            } else {
                ContentUnavailableView(
                    state.hasFoundDuplicates ? FilesText.noDuplicates : FilesText.duplicatesNotScanned,
                    systemImage: "doc.on.doc"
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } else {
            ScrollView {
                LazyVStack(spacing: 12) {
                    ForEach(state.duplicateGroups) { DuplicateGroupView(group: $0, state: state) }
                }
            }
        }
    }
}
