import Foundation
import MainternanceDomain

/// Composes one `SystemSnapshot` from the live readers. Construct it ONCE and reuse it: the CPU reader keeps
/// the baseline of the previous sample, so a fresh provider per poll would never produce a CPU value.
public struct LiveSystemSnapshotProvider: SystemSnapshotProviding {
    private let disk: DiskReader
    private let memory: MemoryPressureReader
    private let thermal: ThermalReader
    private let battery: BatteryReader
    private let cpu: CPUReader
    private let gpu: GPUReader

    public init(
        disk: DiskReader = .init(),
        memory: MemoryPressureReader = .init(),
        thermal: ThermalReader = .init(),
        battery: BatteryReader = .init(),
        cpu: CPUReader = .init(),
        gpu: GPUReader = .init()
    ) {
        self.disk = disk
        self.memory = memory
        self.thermal = thermal
        self.battery = battery
        self.cpu = cpu
        self.gpu = gpu
    }

    /// Unknown values stay nil. An unreadable disk gives total 0 and free 0 (the evaluator reports it as
    /// "Disk size unavailable"). There is no public temperature source, the startup-item count and the OS
    /// update state have no engine yet, so those three are always nil.
    public func currentSnapshot() async -> SystemSnapshot {
        let volume = disk.read()
        return SystemSnapshot(
            diskTotalBytes: volume?.total ?? 0,
            diskFreeBytes: volume?.free ?? 0,
            memoryPressure: memory.read(),
            thermal: thermal.read(),
            cpuUsage: cpu.usage(),
            gpuUsage: gpu.usage(),
            temperatureCelsius: nil,
            battery: battery.read(),
            newStartupItemCount: nil,
            osUpdateAvailable: nil
        )
    }
}
