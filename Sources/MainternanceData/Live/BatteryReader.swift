import Foundation
import IOKit
import MainternanceDomain

/// Raw, unvalidated values from the `AppleSmartBattery` registry entry.
public struct RawBattery: Equatable, Sendable {
    public var currentPercent: Int?
    public var isCharging: Bool?
    public var externalConnected: Bool?
    public var cycleCount: Int?
    public var designCapacity: Int?
    public var fullChargeCapacity: Int?

    public init(
        currentPercent: Int?,
        isCharging: Bool?,
        externalConnected: Bool?,
        cycleCount: Int?,
        designCapacity: Int?,
        fullChargeCapacity: Int?
    ) {
        self.currentPercent = currentPercent
        self.isCharging = isCharging
        self.externalConnected = externalConnected
        self.cycleCount = cycleCount
        self.designCapacity = designCapacity
        self.fullChargeCapacity = fullChargeCapacity
    }
}

/// Reads the battery state from the public IOKit registry. Returns nil when there is no battery.
public struct BatteryReader: Sendable {
    private let readRaw: @Sendable () -> RawBattery?

    public init(read: @escaping @Sendable () -> RawBattery? = BatteryReader.readSystem) {
        readRaw = read
    }

    public func read() -> BatterySnapshot? {
        Self.map(readRaw())
    }

    /// Pure mapping with clamping; unknown values stay nil.
    public static func map(_ raw: RawBattery?) -> BatterySnapshot? {
        guard let raw, let percent = raw.currentPercent else { return nil }
        return BatterySnapshot(
            percent: min(max(percent, 0), 100),
            isCharging: raw.isCharging ?? false,
            healthPercent: health(design: raw.designCapacity, full: raw.fullChargeCapacity),
            cycleCount: raw.cycleCount.flatMap { $0 >= 0 ? $0 : nil }
        )
    }

    private static func health(design: Int?, full: Int?) -> Int? {
        guard let design, let full, design > 0 else { return nil }
        let ratio = (Double(full) * 100 / Double(design)).rounded()
        guard ratio.isFinite else { return nil }
        return Int(min(max(ratio, 0), 100))
    }

    /// Reads `AppleSmartBattery`; nil on Macs without a battery (desktop, VM).
    @Sendable
    public static func readSystem() -> RawBattery? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }

        var unmanaged: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &unmanaged, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let props = unmanaged?.takeRetainedValue() as? [String: Any]
        else { return nil }

        let data = props["BatteryData"] as? [String: Any]
        return RawBattery(
            currentPercent: props["CurrentCapacity"] as? Int,
            isCharging: props["IsCharging"] as? Bool,
            externalConnected: props["ExternalConnected"] as? Bool,
            cycleCount: props["CycleCount"] as? Int,
            designCapacity: data?["DesignCapacity"] as? Int ?? props["DesignCapacity"] as? Int,
            fullChargeCapacity: data?["FullChargeCapacity"] as? Int ?? props["AppleRawMaxCapacity"] as? Int
        )
    }
}
