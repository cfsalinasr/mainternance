import Foundation
import MainternanceDomain

public struct MenuBarLabel: Equatable {
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
        let formatter = ByteCountFormatter()
        formatter.countStyle = .decimal
        formatter.allowedUnits = [.useGB]
        formatter.includesUnit = true
        return MenuBarLabel(
            symbol: state == .good ? "checkmark.shield" : "exclamationmark.shield",
            state: state,
            text: formatter.string(fromByteCount: max(overview.snapshot.diskFreeBytes, 0))
        )
    }
}
