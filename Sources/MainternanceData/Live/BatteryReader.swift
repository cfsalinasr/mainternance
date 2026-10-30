import Foundation
import IOKit
import MainternanceDomain

/// Raw, unvalidated values from the `AppleSmartBattery` registry entry.
public struct RawBattery: Equatable, Sendable {
    /// `CurrentCapacity`: a percent on Apple silicon, but it may be mAh on Intel Macs.
    public var currentCapacity: Int?
    /// `MaxCapacity`, in the same unit as `currentCapacity` (100 on Apple silicon, mAh on Intel).
    public var maxCapacity: Int?
    public var isCharging: Bool?
    public var externalConnected: Bool?
    public var cycleCount: Int?
    public var designCapacity: Int?
    public var fullChargeCapacity: Int?

    public init(
        currentCapacity: Int?,
        maxCapacity: Int?,
        isCharging: Bool?,
        externalConnected: Bool?,
        cycleCount: Int?,
        designCapacity: Int?,
        fullChargeCapacity: Int?
    ) {
        self.currentCapacity = currentCapacity
        self.maxCapacity = maxCapacity
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
        guard let raw, let percent = percent(current: raw.currentCapacity, max: raw.maxCapacity) else { return nil }
        return BatterySnapshot(
            percent: percent,
            isCharging: raw.isCharging ?? false,
            healthPercent: health(design: raw.designCapacity, full: raw.fullChargeCapacity),
            cycleCount: raw.cycleCount.flatMap { $0 >= 0 ? $0 : nil }
        )
    }

    /// `current * 100 / max` when max is usable (works for mAh on Intel and for 100/100 on Apple silicon);
    /// otherwise `current` is taken as a percent. Rounded and clamped to 0...100.
    private static func percent(current: Int?, max maxCapacity: Int?) -> Int? {
        guard let current else { return nil }
        guard let maxCapacity, maxCapacity > 0 else { return min(max(current, 0), 100) }
        let ratio = (Double(current) * 100 / Double(maxCapacity)).rounded()
        guard ratio.isFinite else { return nil }
        return Int(min(max(ratio, 0), 100))
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

        return parse(props)
    }

    /// Pure parsing of the registry dictionary. Values of the wrong type or negative numbers are ignored
    /// (nil). `BatteryData` holds the capacities on current macOS; the top-level `DesignCapacity` and
    /// `AppleRawMaxCapacity` are fallbacks. Never nil today; optional so a future check can reject input.
    public static func parse(_ properties: [String: Any]) -> RawBattery? {
        let data = properties["BatteryData"] as? [String: Any]
        return RawBattery(
            currentCapacity: count(properties["CurrentCapacity"]),
            maxCapacity: count(properties["MaxCapacity"]),
            isCharging: properties["IsCharging"] as? Bool,
            externalConnected: properties["ExternalConnected"] as? Bool,
            cycleCount: count(properties["CycleCount"]),
            designCapacity: count(data?["DesignCapacity"]) ?? count(properties["DesignCapacity"]),
            fullChargeCapacity: count(data?["FullChargeCapacity"]) ?? count(properties["AppleRawMaxCapacity"])
        )
    }

    /// A non-negative integer, or nil for anything else.
    private static func count(_ value: Any?) -> Int? {
        guard let number = value as? Int, number >= 0 else { return nil }
        return number
    }
}
