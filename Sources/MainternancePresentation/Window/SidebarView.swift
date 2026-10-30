import MainternanceDomain
import SwiftUI

/// The sidebar list; the system gives a `NavigationSplitView` sidebar its glass material.
struct SidebarView: View {
    let navigation: Navigation

    var body: some View {
        List(selection: Binding(get: { navigation.selection }, set: { navigation.open($0 ?? navigation.selection) })) {
            ForEach(SidebarItem.visible) { item in
                HStack {
                    Label(item.title, systemImage: item.symbol)
                    if SampleDataCopy.isSample(item.destination) {
                        Spacer()
                        Text(SampleDataCopy.sidebarMarker).font(.caption2).foregroundStyle(.secondary)
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(
                    SampleDataCopy.sidebarAccessibilityLabel(title: item.title, destination: item.destination)
                )
                .tag(item.destination)
            }
        }
        .navigationSplitViewColumnWidth(min: 170, ideal: 190, max: 240)
    }
}
