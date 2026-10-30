import Foundation
import MainternanceDomain
import Observation

/// One point of the sparkline history; taken from a refresh that finished while the model was visible.
public struct OverviewSample: Equatable, Sendable {
    public var cpu: Double?
    public var gpu: Double?
    public var memoryPressure: MemoryPressure?
    public var date: Date

    public init(cpu: Double?, gpu: Double?, memoryPressure: MemoryPressure?, at date: Date) {
        self.cpu = cpu
        self.gpu = gpu
        self.memoryPressure = memoryPressure
        self.date = date
    }
}

@MainActor
@Observable
public final class OverviewViewModel {
    public static let historyLimit = 30

    public private(set) var overview: Overview?
    /// The last `historyLimit` samples, appended only while the model is visible.
    public private(set) var history: [OverviewSample] = []

    @ObservationIgnored private let load: LoadOverview
    @ObservationIgnored private let policy: SamplingPolicy
    @ObservationIgnored private let isLowPowerMode: @Sendable () -> Bool
    @ObservationIgnored private let sleep: @Sendable (Duration) async throws -> Void
    @ObservationIgnored private var isVisible = false
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var isLoading = false
    @ObservationIgnored private var joiners: [CheckedContinuation<Void, Never>] = []
    /// Callers currently suspended on an in-flight load; lets tests wait for a join instead of guessing.
    var pendingJoinerCount: Int {
        joiners.count
    }

    /// A finished load its (cancelled) starter did not publish; the first active joiner claims it.
    @ObservationIgnored private var unpublished: Overview?

    public init(
        load: LoadOverview,
        policy: SamplingPolicy = .init(),
        isLowPowerMode: @escaping @Sendable () -> Bool = { ProcessInfo.processInfo.isLowPowerModeEnabled },
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.load = load
        self.policy = policy
        self.isLowPowerMode = isLowPowerMode
        self.sleep = sleep
    }

    /// Loads and publishes a fresh overview. A result that arrives after the calling task (such as the
    /// loop) was cancelled is dropped, so a stopped or restarted loop never writes stale state.
    /// Calls made while a load is in flight join it instead of starting another, so a manual refresh that
    /// overlaps the loop's refresh produces one load and one history sample.
    public func refresh() async {
        if isLoading {
            // A result the (cancelled) starter did not publish goes to the first joiner that is still
            // active; cancelled joiners never consume it.
            await withCheckedContinuation { joiners.append($0) }
            if !Task.isCancelled, let claimed = unpublished {
                unpublished = nil
                publish(claimed)
            }
            return
        }
        isLoading = true
        unpublished = nil
        let loaded = await load()
        isLoading = false
        let published = !Task.isCancelled
        if published {
            publish(loaded)
        }
        if !published, !joiners.isEmpty {
            unpublished = loaded
        }
        let waiting = joiners
        joiners.removeAll()
        for joiner in waiting {
            joiner.resume()
        }
    }

    private func publish(_ loaded: Overview) {
        overview = loaded
        guard isVisible else { return }
        history.append(OverviewSample(
            cpu: loaded.snapshot.cpuUsage, gpu: loaded.snapshot.gpuUsage,
            memoryPressure: loaded.snapshot.memoryPressure, at: Date()
        ))
        if history.count > Self.historyLimit {
            history.removeFirst(history.count - Self.historyLimit)
        }
    }

    /// Changes the cadence. A running loop is restarted so the new interval applies: becoming visible
    /// refreshes now, becoming hidden waits a full (hidden) interval first.
    public func setVisible(_ visible: Bool) {
        guard visible != isVisible else { return }
        isVisible = visible
        if loop != nil {
            startLoop(refreshFirst: visible)
        }
    }

    public func start() {
        guard loop == nil else { return }
        startLoop(refreshFirst: true)
    }

    public func stop() {
        loop?.cancel()
        loop = nil
    }

    isolated deinit {
        loop?.cancel()
    }

    /// Refreshes (optionally) and returns how long to sleep and how.
    private func step(refreshFirst: Bool) async -> (Duration, @Sendable (Duration) async throws -> Void) {
        if refreshFirst {
            await refresh()
        }
        return (policy.interval(isVisible: isVisible, isLowPowerMode: isLowPowerMode()), sleep)
    }

    private func startLoop(refreshFirst: Bool) {
        loop?.cancel()
        loop = Task { [weak self] in
            var refreshFirst = refreshFirst
            while !Task.isCancelled {
                // `self` is only held strongly inside this call, never across the sleep below.
                guard let (interval, sleep) = await self?.step(refreshFirst: refreshFirst) else { return }
                refreshFirst = true
                guard !Task.isCancelled else { return }
                do { try await sleep(interval) } catch { return }
                // A released sleep must not trigger work once the loop was stopped or replaced.
                guard !Task.isCancelled else { return }
            }
        }
    }
}
