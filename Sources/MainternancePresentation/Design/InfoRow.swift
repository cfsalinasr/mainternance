import MainternanceDomain
import SwiftUI

public struct InfoRow: View {
    private let title: String
    private let value: String
    private let symbol: String
    private let state: HealthState

    public init(title: String, value: String, symbol: String, state: HealthState = .good) {
        self.title = title
        self.value = value
        self.symbol = symbol
        self.state = state
    }

    public var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .frame(width: 20)
                .foregroundStyle(.secondary)
            Text(title)
            Spacer()
            Text(value)
                .foregroundStyle(state == .good ? Color.secondary : state.color)
        }
        .font(.system(size: 13))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title), \(value)\(state.accessibilityNote)")
    }
}
