import Foundation
import MainternanceDomain
import Observation

@MainActor
@Observable
public final class OverviewViewModel {
    public private(set) var overview: Overview?

    @ObservationIgnored private let load: LoadOverview
    @ObservationIgnored private let policy: SamplingPolicy
    @ObservationIgnored private let isLowPowerMode: @Sendable () -> Bool
    @ObservationIgnored private let sleep: @Sendable (Duration) async throws -> Void
    @ObservationIgnored private var isVisible = false
    @ObservationIgnored private var loop: Task<Void, Never>?

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

    public func refresh() async {
        let loaded = await load()
        overview = loaded
    }

    /// Changes the cadence; a running loop is restarted so the new interval applies and a refresh happens now.
    public func setVisible(_ visible: Bool) {
        guard visible != isVisible else { return }
        isVisible = visible
        if loop != nil {
            startLoop()
        }
    }

    public func start() {
        guard loop == nil else { return }
        startLoop()
    }

    public func stop() {
        loop?.cancel()
        loop = nil
    }

    private func startLoop() {
        loop?.cancel()
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await refresh()
                guard !Task.isCancelled else { return }
                let interval = policy.interval(isVisible: isVisible, isLowPowerMode: isLowPowerMode())
                let sleep = sleep
                do { try await sleep(interval) } catch { return }
                // A released sleep must not trigger work once the loop was stopped or replaced.
                guard !Task.isCancelled else { return }
            }
        }
    }
}
