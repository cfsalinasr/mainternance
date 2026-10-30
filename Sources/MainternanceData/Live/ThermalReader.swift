import Foundation
import MainternanceDomain

/// Reads the system thermal state.
public struct ThermalReader: Sendable {
    private let readRaw: @Sendable () -> ProcessInfo.ThermalState

    public init(read: @escaping @Sendable () -> ProcessInfo.ThermalState = { ProcessInfo.processInfo.thermalState }) {
        readRaw = read
    }

    public func read() -> ThermalLevel {
        Self.map(readRaw())
    }

    /// Pure mapping; unknown future states are reported conservatively as `.serious`.
    public static func map(_ state: ProcessInfo.ThermalState) -> ThermalLevel {
        switch state {
        case .nominal: .nominal
        case .fair: .fair
        case .serious: .serious
        case .critical: .critical
        @unknown default: .serious
        }
    }
}
