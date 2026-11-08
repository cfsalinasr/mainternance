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
    /// Nil when unknown (the memory check is then omitted).
    public var memoryPressure: MemoryPressure?
    public var thermal: ThermalLevel
    /// Nil when unknown, such as before the first CPU delta exists (never shown as 0%).
    public var cpuUsage: Double?
    public var gpuUsage: Double?
    public var temperatureCelsius: Double?
    public var battery: BatterySnapshot?
    /// Nil when unknown (never shown as 0).
    public var newStartupItemCount: Int?
    /// A review baseline exists but cannot be read or saved, so new or changed items cannot be told apart: Home
    /// says it could not check (never "nothing new"). Only meaningful while `newStartupItemCount` is nil.
    public var startupCheckUnavailable = false
    /// Nil when unknown (never shown as up to date).
    public var osUpdateAvailable: Bool?

    public init(
        diskTotalBytes: Int64,
        diskFreeBytes: Int64,
        memoryPressure: MemoryPressure?,
        thermal: ThermalLevel,
        cpuUsage: Double?,
        gpuUsage: Double?,
        temperatureCelsius: Double?,
        battery: BatterySnapshot?,
        newStartupItemCount: Int?,
        osUpdateAvailable: Bool?
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
    /// A scan was started and neither completed, cancelled nor failed on record (the app was quit or crashed
    /// during it), so what it would have found is unknown.
    public var lastScanDidNotFinish: Bool
    /// The saved results exist but could not be read, so neither "never scanned" nor "no findings" can be claimed.
    public var savedResultsUnreadable: Bool
    /// The weekly scan is on and its slot is due, but the scanner cannot start it (for example the virus
    /// definitions are missing): it is waiting, so no time may be promised. `nextScan` is nil then.
    public var weeklyScanWaiting: Bool

    public init(
        lastScan: Date?, nextScan: Date?, unresolvedFindings: Int, lastScanDidNotFinish: Bool = false,
        savedResultsUnreadable: Bool = false, weeklyScanWaiting: Bool = false
    ) {
        self.savedResultsUnreadable = savedResultsUnreadable
        self.weeklyScanWaiting = weeklyScanWaiting
        self.lastScan = lastScan
        self.nextScan = nextScan
        self.unresolvedFindings = unresolvedFindings
        self.lastScanDidNotFinish = lastScanDidNotFinish
    }
}
