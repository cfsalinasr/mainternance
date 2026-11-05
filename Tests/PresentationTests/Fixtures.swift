import Foundation
import MainternanceDomain
import Synchronization
import Testing

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
///
/// A sleep registers (so `waitForSleeps` sees it) and then suspends in a second step; `releaseAll()` also releases
/// sleeps that registered but have not suspended yet, so a release that lands between the two steps is never lost.
/// `waitForSleeps` gives up after `timeout` and records an issue, so a sleep that never comes fails the test
/// instead of hanging the run.
actor FakeSleeper {
    private(set) var durations: [Duration] = []
    private var pending: [Int: CheckedContinuation<Void, any Error>] = [:]
    private var cancelled: Set<Int> = []
    /// Registered but not suspended yet.
    private var registered: Set<Int> = []
    /// Released by `releaseAll()` before they suspended: they return as soon as they do.
    private var released: Set<Int> = []
    private var nextID = 0
    private var waiters: [Int: (count: Int, continuation: CheckedContinuation<Void, Never>)] = [:]
    private var nextWaiter = 0
    private let honorsCancellation: Bool
    private let timeout: Duration

    init(honorsCancellation: Bool = true, timeout: Duration = .seconds(10)) {
        self.honorsCancellation = honorsCancellation
        self.timeout = timeout
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

    /// The first step of `sleep`; internal so a test can stop between the two steps.
    func register(_ duration: Duration) -> Int {
        durations.append(duration)
        let id = nextID
        nextID += 1
        registered.insert(id)
        let ready = waiters.filter { durations.count >= $0.value.count }
        for (key, waiter) in ready {
            waiters.removeValue(forKey: key)
            waiter.continuation.resume()
        }
        return id
    }

    /// The second step of `sleep`.
    func suspend(_ id: Int) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            registered.remove(id)
            if cancelled.contains(id) {
                continuation.resume(throwing: CancellationError())
            } else if released.remove(id) != nil {
                continuation.resume()
            } else {
                pending[id] = continuation
            }
        }
    }

    private func cancel(_ id: Int) {
        cancelled.insert(id)
        pending.removeValue(forKey: id)?.resume(throwing: CancellationError())
    }

    /// Lets every requested sleep return normally: those suspended now, and those registered but not yet
    /// suspended (they return at once when they do).
    func releaseAll() {
        released.formUnion(registered)
        let all = pending
        pending.removeAll()
        for continuation in all.values {
            continuation.resume()
        }
    }

    /// Suspends until at least `count` sleeps have been requested, or records an issue after `timeout`.
    func waitForSleeps(_ count: Int, sourceLocation: SourceLocation = #_sourceLocation) async {
        if durations.count >= count {
            return
        }
        let key = nextWaiter
        nextWaiter += 1
        let limit = timeout
        let expiry = Task { [weak self] in
            try? await Task.sleep(for: limit)
            await self?.expire(key, sourceLocation: sourceLocation)
        }
        await withCheckedContinuation { waiters[key] = (count, $0) }
        expiry.cancel()
    }

    private func expire(_ key: Int, sourceLocation: SourceLocation) {
        guard let waiter = waiters.removeValue(forKey: key) else { return }
        Issue.record(
            "timed out waiting for \(waiter.count) sleeps (got \(durations.count))",
            sourceLocation: sourceLocation
        )
        waiter.continuation.resume()
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
