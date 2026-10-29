import SwiftUI

struct DuplicateGroupView: View {
    let group: DuplicateGroup
    let rule: KeepRule

    var body: some View {
        let selection = DuplicateSelection(group: group.files, rule: rule)
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("\(group.files.count) copies", systemImage: "doc.on.doc").font(.headline)
                Spacer()
                Text("Frees \(formatFileSize(selection.reclaimableBytes))")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(group.files) { file in
                FileResultRow(file: file, badge: selection.isKept(file) ? "Keep" : "Would remove")
                    .opacity(selection.isKept(file) ? 1 : 0.75)
            }
        }
        .accessibilityElement(children: .contain)
    }
}
