import MainternanceDomain
import SwiftUI

public extension HealthState {
    var color: Color {
        switch self {
        case .good: .green
        case .needsAttention: .orange
        case .problem: .red
        }
    }

    var title: String {
        switch self {
        case .good: "Good"
        case .needsAttention: "Needs attention"
        case .problem: "Problem"
        }
    }
}
