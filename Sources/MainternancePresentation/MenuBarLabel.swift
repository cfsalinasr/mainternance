import Foundation
import MainternanceDomain
import SwiftUI

public struct MenuBarLabel: Equatable, Sendable {
    public var symbol: String
    public var state: HealthState
    public var text: String

    public init(symbol: String, state: HealthState, text: String) {
        self.symbol = symbol
        self.state = state
        self.text = text
    }

    public static func make(from overview: Overview?) -> MenuBarLabel {
        guard let overview else {
            return MenuBarLabel(symbol: "shield", state: .good, text: "")
        }
        let state = overview.report.overall
        return MenuBarLabel(
            symbol: state == .good ? "checkmark.shield" : "exclamationmark.shield",
            state: state,
            text: formatBytes(overview.snapshot.diskFreeBytes)
        )
    }
}

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
