import MainternanceDomain
import SwiftUI

/// Placeholder for sections that later tasks replace.
struct ComingSoonView: View {
    let destination: AppDestination

    var body: some View {
        let item = SidebarItem.item(for: destination)
        ContentUnavailableView {
            Label(item.title, systemImage: item.symbol)
        } description: {
            Text("Coming soon")
        }
    }
}
