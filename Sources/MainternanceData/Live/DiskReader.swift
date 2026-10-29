import Foundation

/// Raw capacity values as reported by the system; either may be missing.
public struct RawDisk: Sendable, Equatable {
    public var total: Int64?
    public var importantFree: Int64?

    public init(total: Int64?, importantFree: Int64?) {
        self.total = total
        self.importantFree = importantFree
    }
}

/// Reads total and free space of a volume.
public struct DiskReader: Sendable {
    private let volumeURL: URL
    private let readRaw: @Sendable (URL) -> RawDisk?

    public init(
        volumeURL: URL = URL(fileURLWithPath: "/"),
        read: @escaping @Sendable (URL) -> RawDisk? = DiskReader.readSystem
    ) {
        self.volumeURL = volumeURL
        readRaw = read
    }

    public func read() -> (total: Int64, free: Int64)? {
        Self.map(readRaw(volumeURL))
    }

    /// Pure mapping: nil when total is missing or not positive, or free is missing;
    /// free is clamped to `0...total`.
    public static func map(_ raw: RawDisk?) -> (total: Int64, free: Int64)? {
        guard let raw, let total = raw.total, total > 0, let free = raw.importantFree else { return nil }
        return (total, min(max(free, 0), total))
    }

    /// Uses `volumeAvailableCapacityForImportantUsageKey` on purpose: it is the figure System Settings
    /// shows. Measured once on the reference Mac (the user's): 278 GB for this key, while
    /// `volumeAvailableCapacityKey` said 232 GB and `df` 216 GB, because those exclude purgeable space.
    /// The exact gap differs from Mac to Mac.
    @Sendable
    public static func readSystem(_ url: URL) -> RawDisk? {
        // Foundation caches resource values on a URL instance and nothing else clears that cache, so
        // reading the same URL every poll would return the launch-time figure forever. Clear it first.
        var url = url
        url.removeAllCachedResourceValues()
        let keys: Set<URLResourceKey> = [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey]
        guard let values = try? url.resourceValues(forKeys: keys) else { return nil }
        return RawDisk(
            total: values.volumeTotalCapacity.map(Int64.init),
            importantFree: values.volumeAvailableCapacityForImportantUsage
        )
    }
}
