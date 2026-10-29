import Foundation
import MainternanceDomain
import Synchronization

func makeSnapshot(
    diskFreeBytes: Int64 = 41_000_000_000,
    gpuUsage: Double? = nil,
    temperatureCelsius: Double? = nil,
    battery: BatterySnapshot? = nil
) -> SystemSnapshot {
    SystemSnapshot(
        diskTotalBytes: 500_000_000_000, diskFreeBytes: diskFreeBytes,
        memoryPressure: .normal, thermal: .nominal, cpuUsage: 0.1,
        gpuUsage: gpuUsage, temperatureCelsius: temperatureCelsius, battery: battery,
        newStartupItemCount: 0, osUpdateAvailable: false
    )
}

func makeOverview(state: HealthState, snapshot: SystemSnapshot = makeSnapshot()) -> Overview {
    let check = HealthCheck(id: .diskSpace, state: state, title: "Disk", reason: "reason", destination: .cleanup)
    return Overview(
        snapshot: snapshot,
        scan: ScanStatus(lastScan: nil, nextScan: nil, unresolvedFindings: 0),
        report: HealthReport(checks: [check]),
        actions: []
    )
}

final class CallCounter: Sendable {
    private let storage = Mutex(0)
    var count: Int {
        storage.withLock { $0 }
    }

    func increment() {
        storage.withLock { $0 += 1 }
    }
}

struct FakeSnapshots: SystemSnapshotProviding {
    let counter: CallCounter
    func currentSnapshot() async -> SystemSnapshot {
        counter.increment()
        return makeSnapshot()
    }
}

struct FakeScans: ScanStatusProviding {
    func currentStatus() async -> ScanStatus? {
        ScanStatus(lastScan: Date(timeIntervalSince1970: 0), nextScan: nil, unresolvedFindings: 0)
    }
}

struct FakeActions: SuggestedActionsProviding {
    func suggestedActions() async -> [SuggestedAction] {
        []
    }
}

/// Fake clock: records each requested sleep and suspends until the test releases it.
actor FakeSleeper {
    private(set) var durations: [Duration] = []
    private var pending: [Int: CheckedContinuation<Void, any Error>] = [:]
    private var cancelled: Set<Int> = []
    private var nextID = 0
    private var waiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []
    private let honorsCancellation: Bool

    init(honorsCancellation: Bool = true) {
        self.honorsCancellation = honorsCancellation
    }

    nonisolated func sleep(_ duration: Duration) async throws {
        let id = await register(duration)
        if honorsCancellation {
            try await withTaskCancellationHandler {
                try await suspend(id)
            } onCancel: {
                Task { await self.cancel(id) }
            }
        } else {
            try await suspend(id)
        }
    }

    private func register(_ duration: Duration) -> Int {
        durations.append(duration)
        let ready = waiters.filter { durations.count >= $0.count }
        waiters.removeAll { durations.count >= $0.count }
        for waiter in ready {
            waiter.continuation.resume()
        }
        defer { nextID += 1 }
        return nextID
    }

    private func suspend(_ id: Int) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            if cancelled.contains(id) {
                continuation.resume(throwing: CancellationError())
            } else {
                pending[id] = continuation
            }
        }
    }

    private func cancel(_ id: Int) {
        cancelled.insert(id)
        pending.removeValue(forKey: id)?.resume(throwing: CancellationError())
    }

    /// Lets every suspended sleep return normally.
    func releaseAll() {
        let all = pending
        pending.removeAll()
        for continuation in all.values {
            continuation.resume()
        }
    }

    /// Suspends until at least `count` sleeps have been requested.
    func waitForSleeps(_ count: Int) async {
        if durations.count >= count {
            return
        }
        await withCheckedContinuation { waiters.append((count, $0)) }
    }
}

/// Holds a load open until the test lets it through, so a refresh can be observed mid-flight.
actor LoadGate {
    /// How many loads have reached the gate.
    private(set) var entered = 0
    private var isOpen = false
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    private var openWaiters: [CheckedContinuation<Void, Never>] = []

    func pass() async {
        entered += 1
        let waiting = entryWaiters
        entryWaiters.removeAll()
        for waiter in waiting {
            waiter.resume()
        }
        if isOpen {
            return
        }
        await withCheckedContinuation { openWaiters.append($0) }
    }

    func waitForEntry() async {
        if entered > 0 {
            return
        }
        await withCheckedContinuation { entryWaiters.append($0) }
    }

    func open() {
        isOpen = true
        let waiting = openWaiters
        openWaiters.removeAll()
        for waiter in waiting {
            waiter.resume()
        }
    }
}

struct GatedSnapshots: SystemSnapshotProviding {
    let gate: LoadGate
    func currentSnapshot() async -> SystemSnapshot {
        await gate.pass()
        return makeSnapshot()
    }
}
