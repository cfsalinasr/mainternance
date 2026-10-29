import MainternanceDomain
import SwiftUI

struct SuggestedActionsCard: View {
    let actions: [SuggestedAction]
    let emptyText: String?
    let open: (AppDestination) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Suggested").font(.caption).foregroundStyle(.secondary)
            if let emptyText {
                Text(emptyText).font(.system(size: 13)).foregroundStyle(.secondary)
            }
            ForEach(actions) { action in
                Button { open(action.destination) } label: {
                    HStack(spacing: 12) {
                        Image(systemName: action.symbol).frame(width: 22).foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(action.title).font(.system(size: 14))
                            Text(action.detail).font(.system(size: 12)).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right").font(.system(size: 12)).foregroundStyle(.tertiary)
                    }
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(action.title), \(action.detail)")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .solidCard()
    }
}
