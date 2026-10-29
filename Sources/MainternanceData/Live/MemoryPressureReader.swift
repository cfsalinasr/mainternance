import Darwin
import MainternanceDomain

/// Reads the kernel's memory pressure level.
public struct MemoryPressureReader: Sendable {
    private let readRaw: @Sendable () -> Int32?

    public init(read: @escaping @Sendable () -> Int32? = MemoryPressureReader.readSystem) {
        readRaw = read
    }

    public func read() -> MemoryPressure? {
        Self.map(readRaw())
    }

    /// Pure mapping: 1 normal, 2 warning, 4 critical; anything else is unknown (nil).
    public static func map(_ level: Int32?) -> MemoryPressure? {
        switch level {
        case 1: .normal
        case 2: .warning
        case 4: .critical
        default: nil
        }
    }

    /// Thin wrapper over `sysctlbyname`; a failed or short read yields nil.
    @Sendable
    public static func readSystem() -> Int32? {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        let status = sysctlbyname("kern.memorystatus_vm_pressure_level", &value, &size, nil, 0)
        guard status == 0, size == MemoryLayout<Int32>.size else { return nil }
        return value
    }
}
