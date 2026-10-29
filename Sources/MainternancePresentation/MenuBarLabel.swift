import Foundation
import MainternanceDomain
import Synchronization

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
            text: formatFreeSpace(overview.snapshot.diskFreeBytes)
        )
    }
}

/// One formatter shared by every call; the lock keeps access safe under Swift 6.
private let freeSpaceFormatter: Mutex<ByteCountFormatter> = {
    let formatter = ByteCountFormatter()
    formatter.countStyle = .decimal
    formatter.allowedUnits = [.useGB]
    formatter.includesUnit = true
    formatter.allowsNonnumericFormatting = false
    return Mutex(formatter)
}()

/// The single byte-formatting path (decimal GB, e.g. "41 GB") shared by the menu bar label and the popover.
func formatFreeSpace(_ bytes: Int64) -> String {
    freeSpaceFormatter.withLock { $0.string(fromByteCount: max(bytes, 0)) }
}
