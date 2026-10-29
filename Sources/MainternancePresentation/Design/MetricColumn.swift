import MainternanceDomain
import SwiftUI

public struct MetricColumn: View {
    private let title: String
    private let symbol: String
    private let value: String
    private let state: HealthState

    public init(title: String, symbol: String, value: String, state: HealthState) {
        self.title = title
        self.symbol = symbol
        self.value = value
        self.state = state
    }

    public var body: some View {
        VStack(spacing: 4) {
            Image(systemName: symbol)
                .font(.system(size: 18))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(state.color)
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title), \(value)")
    }
}
