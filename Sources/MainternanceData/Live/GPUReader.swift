import Foundation
import IOKit

/// Reads GPU utilization from the IOKit accelerator registry (best effort; nil when unavailable).
public struct GPUReader: Sendable {
    private let readRaw: @Sendable () -> Int?

    public init(read: @escaping @Sendable () -> Int? = GPUReader.readSystem) {
        readRaw = read
    }

    /// GPU busy fraction `0...1`, or nil when it cannot be read.
    public func usage() -> Double? {
        Self.map(readRaw())
    }

    /// Pure: nil stays nil; a percentage is clamped to 0...100 and divided by 100.
    public static func map(_ percent: Int?) -> Double? {
        guard let percent else { return nil }
        return Double(min(max(percent, 0), 100)) / 100
    }

    /// Maximum `Device Utilization %` across all `IOAccelerator` services; nil when none reports it.
    @Sendable
    public static func readSystem() -> Int? {
        guard let matching = IOServiceMatching("IOAccelerator") else { return nil }
        var iterator: io_iterator_t = 0
        // IOServiceGetMatchingServices consumes the matching dictionary reference.
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else {
            return nil
        }
        defer { IOObjectRelease(iterator) }
        var best: Int?
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            if let value = utilization(of: service) {
                best = max(best ?? value, value)
            }
        }
        return best
    }

    private static func utilization(of service: io_registry_entry_t) -> Int? {
        // IORegistryEntryCreateCFProperty follows the Create rule: takeRetainedValue() exactly once.
        guard let raw = IORegistryEntryCreateCFProperty(
            service, "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0
        )
        else { return nil }
        let stats = raw.takeRetainedValue() as? [String: Any]
        guard let number = stats?["Device Utilization %"] as? NSNumber else { return nil }
        return number.intValue
    }
}
