import SwiftUI

/// Sample view for the hidden Duplicates tab; Task 6 replaces it with the real one.
struct DuplicateGroupView: View {
    let group: SampleDuplicateGroup
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
                SampleFileRow(file: file, badge: selection.isKept(file) ? "Keep" : "Would remove")
                    .opacity(selection.isKept(file) ? 1 : 0.75)
            }
        }
        .accessibilityElement(children: .contain)
    }
}

private struct SampleFileRow: View {
    let file: SampleFile
    let badge: String

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(file.name).font(.system(size: 13, weight: .medium)).lineLimit(1).truncationMode(.middle)
                    Text(badge).font(.caption2.weight(.semibold))
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(.quaternary, in: Capsule())
                }
                Text(file.path).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 8)
            Text(formatFileSize(file.size)).font(.system(size: 12, weight: .medium)).monospacedDigit()
        }
        .solidCard()
        .accessibilityElement(children: .combine)
    }
}
