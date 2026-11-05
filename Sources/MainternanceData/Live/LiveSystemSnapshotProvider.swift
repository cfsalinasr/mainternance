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
    private let startup: (any StartupListing)?

    /// `startup` gives Home its count of new startup items (the app passes `StartupServices.newItemCounter`, which
    /// never runs launchctl or writes); without it the count is unknown.
    public init(
        disk: DiskReader = .init(),
        memory: MemoryPressureReader = .init(),
        thermal: ThermalReader = .init(),
        battery: BatteryReader = .init(),
        cpu: CPUReader = .init(),
        gpu: GPUReader = .init(),
        startup: (any StartupListing)? = nil
    ) {
        self.disk = disk
        self.memory = memory
        self.thermal = thermal
        self.battery = battery
        self.cpu = cpu
        self.gpu = gpu
        self.startup = startup
    }

    /// Unknown values stay nil. An unreadable disk gives total 0 and free 0 (the evaluator reports it as
    /// "Disk size unavailable"). There is no public temperature source and the OS update state has no engine yet,
    /// so those two are always nil. The new startup item count is nil until a review baseline exists (and while it
    /// cannot be read), so Home says nothing rather than "0".
    public func currentSnapshot() async -> SystemSnapshot {
        let volume = disk.read()
        var startupCount: Int?
        var startupUnavailable = false
        if let startup {
            (startupCount, startupUnavailable) = await Self.newCount(startup)
        }
        var snapshot = SystemSnapshot(
            diskTotalBytes: volume?.total ?? 0,
            diskFreeBytes: volume?.free ?? 0,
            memoryPressure: memory.read(),
            thermal: thermal.read(),
            cpuUsage: cpu.usage(),
            gpuUsage: gpu.usage(),
            temperatureCelsius: nil,
            battery: battery.read(),
            newStartupItemCount: startupCount,
            osUpdateAvailable: nil
        )
        snapshot.startupCheckUnavailable = startupUnavailable
        return snapshot
    }

    /// The count, or nil with `unavailable` when a baseline exists but cannot be read or saved (then nothing is
    /// marked, and a zero would claim "nothing new").
    private static func newCount(_ lister: any StartupListing) async -> (count: Int?, unavailable: Bool) {
        let snapshot = await lister.list()
        guard snapshot.baselineEstablished || snapshot.reviewUnreadable else { return (nil, false) }
        guard !snapshot.reviewUnreadable, !snapshot.reviewReadOnly else { return (nil, true) }
        return (snapshot.newCount, false)
    }
}
