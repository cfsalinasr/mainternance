import MainternanceDomain
import SwiftUI

/// One real file: name, folder, size and date, with Quick Look and Reveal in Finder. Names and paths are shown
/// cleaned; the buttons act on the real path through the state.
struct FileResultRow: View {
    let file: FileItem
    let quickLook: () -> Void
    let reveal: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: file.kind.symbol)
                .font(.system(size: 18))
                .frame(width: 28)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(file.displayName).font(.system(size: 13, weight: .medium)).lineLimit(1).truncationMode(.middle)
                Text(file.displayPath).font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 2) {
                Text(formatFileSize(file.bytes)).font(.system(size: 12, weight: .medium)).monospacedDigit()
                Text(file.modified.formatted(date: .abbreviated, time: .omitted))
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack(spacing: 4) {
                Button(action: quickLook) { Image(systemName: "eye") }
                    .help(FilesText.quickLook)
                    .accessibilityLabel(FilesText.quickLook)
                Button(action: reveal) { Image(systemName: "folder") }
                    .help(FilesText.reveal)
                    .accessibilityLabel(FilesText.reveal)
            }
            .buttonStyle(.borderless)
        }
        .solidCard()
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilityText)
    }

    private var accessibilityText: String {
        let modified = file.modified.formatted(date: .abbreviated, time: .omitted)
        return "\(file.displayName), \(formatFileSize(file.bytes)), modified \(modified), \(file.displayPath)"
    }
}
