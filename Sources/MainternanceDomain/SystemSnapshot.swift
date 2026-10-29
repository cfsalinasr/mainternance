import Foundation

public enum MemoryPressure: Sendable, Equatable {
    case normal, warning, critical
}

public enum ThermalLevel: Sendable, Equatable {
    case nominal, fair, serious, critical
}

public struct BatterySnapshot: Sendable, Equatable {
    public var percent: Int
    public var isCharging: Bool
    public var healthPercent: Int?
    public var cycleCount: Int?

    public init(percent: Int, isCharging: Bool, healthPercent: Int?, cycleCount: Int?) {
        self.percent = percent
        self.isCharging = isCharging
        self.healthPercent = healthPercent
        self.cycleCount = cycleCount
    }
}

public struct SystemSnapshot: Sendable, Equatable {
    public var diskTotalBytes: Int64
    public var diskFreeBytes: Int64
    public var memoryPressure: MemoryPressure
    public var thermal: ThermalLevel
    public var cpuUsage: Double
    public var gpuUsage: Double?
    public var temperatureCelsius: Double?
    public var battery: BatterySnapshot?
    public var newStartupItemCount: Int
    public var osUpdateAvailable: Bool

    public init(
        diskTotalBytes: Int64,
        diskFreeBytes: Int64,
        memoryPressure: MemoryPressure,
        thermal: ThermalLevel,
        cpuUsage: Double,
        gpuUsage: Double?,
        temperatureCelsius: Double?,
        battery: BatterySnapshot?,
        newStartupItemCount: Int,
        osUpdateAvailable: Bool
    ) {
        self.diskTotalBytes = diskTotalBytes
        self.diskFreeBytes = diskFreeBytes
        self.memoryPressure = memoryPressure
        self.thermal = thermal
        self.cpuUsage = cpuUsage
        self.gpuUsage = gpuUsage
        self.temperatureCelsius = temperatureCelsius
        self.battery = battery
        self.newStartupItemCount = newStartupItemCount
        self.osUpdateAvailable = osUpdateAvailable
    }
}

public struct ScanStatus: Sendable, Equatable {
    public var lastScan: Date?
    public var nextScan: Date?
    public var unresolvedFindings: Int

    public init(lastScan: Date?, nextScan: Date?, unresolvedFindings: Int) {
        self.lastScan = lastScan
        self.nextScan = nextScan
        self.unresolvedFindings = unresolvedFindings
    }
}
