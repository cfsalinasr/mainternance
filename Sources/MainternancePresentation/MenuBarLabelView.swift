import MainternanceDomain
import SwiftUI

/// The menu bar item's content: the health symbol tinted by state, then the free disk space.
public struct MenuBarLabelView: View {
    private let overview: Overview?

    public init(overview: Overview?) {
        self.overview = overview
    }

    public var body: some View {
        let label = MenuBarLabel.make(from: overview)
        Image(systemName: label.symbol)
            .foregroundStyle(label.state.color)
        Text(label.text)
    }
}
