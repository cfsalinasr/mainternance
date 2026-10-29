import Foundation
import MainternanceDomain

public struct MockSystemSnapshotProvider: SystemSnapshotProviding {
    public init() {}

    public func currentSnapshot() async -> SystemSnapshot {
        SystemSnapshot(
            diskTotalBytes: 460_000_000_000,
            diskFreeBytes: 41_000_000_000,
            memoryPressure: .normal,
            thermal: .nominal,
            cpuUsage: 0.23,
            gpuUsage: 0.08,
            temperatureCelsius: nil,
            battery: BatterySnapshot(percent: 82, isCharging: true, healthPercent: 91, cycleCount: 214),
            newStartupItemCount: 3,
            osUpdateAvailable: false
        )
    }
}
