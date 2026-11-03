import Foundation
import MainternanceDomain
import Synchronization

/// Home's Cleanup suggestion ("Free about N GB in Cleanup"), from the last real measurement.
///
/// Nothing is suggested, and nothing is measured, until the Cleanup screen has measured once (`record`): measuring
/// walks the disk, so it never starts at launch. After that, a Home refresh that finds the estimate older than
/// `minimumAge` starts one measuring in the background and returns the current estimate at once (Home never waits
/// for a disk walk); the new one is used from the next refresh. Such a measuring starts only while Home is on screen
/// (`setHomeVisible`) and never in Low Power Mode; it runs detached at background priority, Home going off screen
/// cancels it, and a new one never starts while one (even a cancelled one) is still running.
///
/// A measuring that finished replaces the estimate, even with a smaller total (that is what is there now); one that
/// was cancelled is dropped and the previous estimate stays. A measurement recorded by the Cleanup screen replaces
/// the estimate at once and cancels a background measuring, whose result is dropped. A clock that went backwards
/// counts as stale.
public final class CleanupEstimate: SuggestedActionsProviding, Sendable {
    static let minimumAge: TimeInterval = 600
    /// Below this total nothing is suggested.
    static let threshold: Int64 = 500_000_000

    private struct State {
        var latest: CleanupMeasurement?
        var takenAt = Date.distantPast
        var generation = 0
        var homeVisible = false
        /// The running background measuring, until it ended (also after being cancelled).
        var walk: Task<Void, Never>?
    }

    private let scanner: any CleanupScanning
    private let now: @Sendable () -> Date
    private let isLowPowerMode: @Sendable () -> Bool
    private let state = Mutex(State())

    init(
        scanner: any CleanupScanning, now: @escaping @Sendable () -> Date,
        isLowPowerMode: @escaping @Sendable () -> Bool = { ProcessInfo.processInfo.isLowPowerModeEnabled }
    ) {
        self.scanner = scanner
        self.now = now
        self.isLowPowerMode = isLowPowerMode
    }

    /// The Cleanup screen measured (or moved items): this is the estimate from now on.
    public func record(_ measurement: CleanupMeasurement) {
        let time = now()
        state.withLock { current in
            current.latest = measurement
            current.takenAt = time
            current.generation += 1
            current.walk?.cancel()
        }
    }

    /// Whether Home (where the suggestion shows) is on screen. Going off screen cancels a running measuring.
    public func setHomeVisible(_ visible: Bool) {
        state.withLock { current in
            current.homeVisible = visible
            if !visible {
                current.walk?.cancel()
            }
        }
    }

    /// True while a background measuring runs (until it ended, also after being cancelled).
    var isRefreshing: Bool {
        state.withLock { $0.walk != nil }
    }

    public func suggestedActions() async -> [SuggestedAction] {
        let time = now()
        let lowPower = isLowPowerMode()
        let latest = state.withLock { current in
            let age = time.timeIntervalSince(current.takenAt)
            let stale = current.latest != nil && !(age >= 0 && age < Self.minimumAge)
            if stale, current.homeVisible, !lowPower, current.walk == nil {
                let generation = current.generation
                current.walk = Task.detached(priority: .background) { [self] in
                    await refresh(generation: generation)
                }
            }
            return current.latest
        }
        return latest.flatMap(Self.action).map { [$0] } ?? []
    }

    private func refresh(generation: Int) async {
        let fresh = await scanner.measure()
        let finished = !Task.isCancelled
        let time = now()
        state.withLock { current in
            current.walk = nil
            guard finished, current.generation == generation else { return }
            current.latest = fresh
            current.takenAt = time
        }
    }

    static func action(_ measurement: CleanupMeasurement) -> SuggestedAction? {
        let total = measurement.totalBytes
        guard total >= threshold else { return nil }
        let size = ByteCountFormatter.string(fromByteCount: total, countStyle: .decimal)
        return SuggestedAction(
            id: "cleanup",
            title: "Free \(measurement.isLowerBound ? "at least" : "about") \(size) in Cleanup",
            detail: "Caches, logs and old installers to review. They move to the Trash, never deleted.",
            symbol: "trash",
            destination: .cleanup
        )
    }
}
