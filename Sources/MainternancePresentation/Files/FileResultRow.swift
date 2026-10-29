import SwiftUI

let fileEngineUnavailableHelp = "Available when the file engine is connected"

struct FileResultRow: View {
    let file: SampleFile
    var badge: String?

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: file.kind.symbol)
                .font(.system(size: 18))
                .frame(width: 28)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(file.name).font(.system(size: 13, weight: .medium)).lineLimit(1).truncationMode(.middle)
                    if let badge {
                        Text(badge).font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(.quaternary, in: Capsule())
                    }
                }
                Text(file.path).font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 2) {
                Text(formatFileSize(file.size)).font(.system(size: 12, weight: .medium)).monospacedDigit()
                Text(file.modified.formatted(date: .abbreviated, time: .omitted))
                    .font(.caption).foregroundStyle(.secondary)
            }
            FileActionButtons()
        }
        .solidCard()
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
    }

    private var accessibilityText: String {
        let modified = file.modified.formatted(date: .abbreviated, time: .omitted)
        let suffix = badge.map { ", \($0)" } ?? ""
        return "\(file.name), \(formatFileSize(file.size)), modified \(modified), \(file.path)\(suffix)"
    }
}

/// Quick Look, Reveal in Finder, Move to Trash: present but inert until the file engine exists.
struct FileActionButtons: View {
    var body: some View {
        HStack(spacing: 4) {
            action("Quick Look", "eye")
            action("Reveal in Finder", "folder")
            action("Move to Trash", "trash")
        }
        .disabled(true)
    }

    private func action(_ title: String, _ symbol: String) -> some View {
        Button {} label: { Image(systemName: symbol) }
            .buttonStyle(.borderless)
            .help(fileEngineUnavailableHelp)
            .accessibilityLabel(title)
            .accessibilityHint(fileEngineUnavailableHelp)
    }
}
