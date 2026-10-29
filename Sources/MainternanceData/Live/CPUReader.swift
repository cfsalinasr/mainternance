import Darwin
import Synchronization

/// Cumulative CPU time counters since boot (they only make sense as a delta between two samples).
public struct CPUTicks: Equatable, Sendable {
    public var user: UInt64
    public var system: UInt64
    public var idle: UInt64
    public var nice: UInt64

    public init(user: UInt64, system: UInt64, idle: UInt64, nice: UInt64) {
        self.user = user
        self.system = system
        self.idle = idle
        self.nice = nice
    }
}

/// Reads overall CPU usage as the busy fraction between two consecutive calls.
public final class CPUReader: Sendable {
    private let readRaw: @Sendable () -> CPUTicks?
    private let previous = Mutex<CPUTicks?>(nil)

    public init(read: @escaping @Sendable () -> CPUTicks? = CPUReader.readSystem) {
        readRaw = read
    }

    /// Busy fraction `0...1` since the previous call. The first call only stores the baseline and returns nil,
    /// as does any call whose sample is unreadable or whose delta is unusable.
    /// Assumes a single poller: overlapping calls from several threads can double-count an interval.
    public func usage() -> Double? {
        guard let current = readRaw() else { return nil }
        let before = previous.withLock { stored -> CPUTicks? in
            let old = stored
            stored = current
            return old
        }
        guard let before else { return nil }
        return Self.usage(previous: before, current: current)
    }

    /// Pure: (delta user + system + nice) / (delta total). Nil when the total delta is 0 or a counter went backwards.
    public static func usage(previous: CPUTicks, current: CPUTicks) -> Double? {
        guard current.user >= previous.user, current.system >= previous.system,
              current.idle >= previous.idle, current.nice >= previous.nice else { return nil }
        // Doubles avoid UInt64 overflow when summing huge deltas.
        let busy = Double(current.user - previous.user)
            + Double(current.system - previous.system)
            + Double(current.nice - previous.nice)
        let total = busy + Double(current.idle - previous.idle)
        guard total > 0, total.isFinite else { return nil }
        let fraction = busy / total
        guard fraction.isFinite else { return nil }
        return min(max(fraction, 0), 1)
    }

    /// `mach_host_self()` returns a NEW send right on every call and nothing releases it, so calling it per poll
    /// would leak one port reference each time. The right is created once and kept for the process lifetime.
    private static let hostPort = mach_host_self()

    /// Thin wrapper over `host_statistics(HOST_CPU_LOAD_INFO)`; any failure yields nil.
    @Sendable
    public static func readSystem() -> CPUTicks? {
        var info = host_cpu_load_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size
        )
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(hostPort, HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard status == KERN_SUCCESS else { return nil }
        // cpu_ticks is a C tuple indexed by the CPU_STATE_* constants.
        let ticks = [info.cpu_ticks.0, info.cpu_ticks.1, info.cpu_ticks.2, info.cpu_ticks.3]
        return CPUTicks(
            user: UInt64(ticks[Int(CPU_STATE_USER)]),
            system: UInt64(ticks[Int(CPU_STATE_SYSTEM)]),
            idle: UInt64(ticks[Int(CPU_STATE_IDLE)]),
            nice: UInt64(ticks[Int(CPU_STATE_NICE)])
        )
    }
}
