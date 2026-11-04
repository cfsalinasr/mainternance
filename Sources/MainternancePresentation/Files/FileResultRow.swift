import MainternanceDomain
import SwiftUI

/// One real file: name, folder, size and date, with Quick Look and Reveal in Finder. Names and paths are shown
/// cleaned; the buttons act on the real path through the state.
struct FileResultRow: View {
    let file: FileItem
    let quickLook: () -> Void
    let reveal: () -> Void
    /// Opens the Trash review for this file; nil hides the button.
    var trash: (() -> Void)?
    var canTrash = true
    /// Keep or Would remove, for a copy in a duplicate group.
    var badge: String?
    /// Why the file could not be moved last time.
    var note: String?

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: file.kind.symbol)
                .font(.system(size: 18))
                .frame(width: 28)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(file.displayName).font(.system(size: 13, weight: .medium))
                        .lineLimit(1).truncationMode(.middle)
                    if let badge {
                        Text(badge).font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(.quaternary, in: Capsule())
                    }
                }
                Text(file.displayPath).font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
                if let note {
                    Text(note).font(.system(size: 11)).foregroundStyle(.secondary)
                }
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
                if let trash {
                    Button(action: trash) { Image(systemName: "trash") }
                        .help(FilesText.trash)
                        .accessibilityLabel(FilesText.trash)
                        .disabled(!canTrash)
                }
            }
            .buttonStyle(.borderless)
        }
        .solidCard()
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilityText)
    }

    private var accessibilityText: String {
        let modified = file.modified.formatted(date: .abbreviated, time: .omitted)
        let tag = badge.map { ", \($0)" } ?? ""
        return "\(file.displayName)\(tag), \(formatFileSize(file.bytes)), modified \(modified), \(file.displayPath)"
    }
}
