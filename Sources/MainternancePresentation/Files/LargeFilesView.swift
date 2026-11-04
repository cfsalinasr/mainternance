import SwiftUI

/// The Large files tab: a Scan button, what the scan is doing, the treemap and the list. Rules live in the state.
struct LargeFilesView: View {
    let state: FilesViewState

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(FilesText.largeIntro).font(.system(size: 12)).foregroundStyle(.secondary)
            controls
            if let note = state.unreadableNote {
                Text(note).font(.system(size: 12)).foregroundStyle(.secondary)
            }
            if let stale = state.staleMapNote {
                Text(stale).font(.system(size: 12)).foregroundStyle(.secondary)
            }
            if state.diskResult == nil {
                if !state.isScanningDisk {
                    ContentUnavailableView(FilesText.notScanned, systemImage: "internaldrive")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    Spacer()
                }
            } else {
                DiskTreemapView(state: state)
                    .frame(height: 260)
                if state.largestFiles.isEmpty {
                    ContentUnavailableView(FilesText.noLargeFiles, systemImage: "doc")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 8) {
                            ForEach(state.largestFiles) { file in
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
        }
    }

    private var controls: some View {
        HStack(spacing: 10) {
            if state.isScanningDisk {
                Button(FilesText.stop) { state.stopDiskScan() }
                ProgressView().controlSize(.small)
                if let progress = state.scanProgressText {
                    Text(progress).font(.system(size: 12)).foregroundStyle(.secondary)
                }
            } else {
                Button(state.diskResult == nil ? FilesText.scan : FilesText.scanAgain) { state.startDiskScan() }
                if state.diskResult != nil {
                    Text(state.totalText).font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
    }
}
