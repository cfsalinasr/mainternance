import SwiftUI

enum SystemHelp {
    static let engineNotConnected = "Available when the system engine is connected"
}

/// A name, an optional secondary line (path or detail) and a trailing size, on one accessible row.
struct PreviewListRow: View {
    let title: String
    var subtitle: String?
    let trailing: String
    /// Set when the row lives in a selectable list, so VoiceOver announces the selection.
    var isSelected = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .medium))
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(subtitle)
                }
            }
            Spacer(minLength: 8)
            Text(trailing).font(.system(size: 13)).foregroundStyle(.secondary).monospacedDigit()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityLabel("\(title), \(trailing)\(subtitle.map { ", \($0)" } ?? "")")
    }
}
