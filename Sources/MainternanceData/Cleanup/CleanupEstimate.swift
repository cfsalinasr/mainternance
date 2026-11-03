import Foundation
import MainternanceDomain
import Synchronization

/// Home's Cleanup suggestion ("Free about N GB in Cleanup"), from the last real measurement.
///
/// Nothing is suggested, and nothing is measured, until the Cleanup screen has measured once (`record`): measuring
/// walks the disk, so it never starts at launch. After that, a Home refresh that finds the estimate older than
/// `minimumAge` starts one measuring in the background and returns the current estimate at once (Home never waits
/// for a disk walk); the new one is used from the next refresh. A measurement recorded by the Cleanup screen
/// replaces the estimate at once, and a background measuring that finishes after it is dropped. A clock that went
/// backwards counts as stale.
public final class CleanupEstimate: SuggestedActionsProviding, Sendable {
    static let minimumAge: TimeInterval = 600
    /// Below this total nothing is suggested.
    static let threshold: Int64 = 500_000_000

    private struct State {
        var latest: CleanupMeasurement?
        var takenAt = Date.distantPast
        var generation = 0
        var refreshing = false
    }

    private let scanner: any CleanupScanning
    private let now: @Sendable () -> Date
    private let state = Mutex(State())

    init(scanner: any CleanupScanning, now: @escaping @Sendable () -> Date) {
        self.scanner = scanner
        self.now = now
    }

    /// The Cleanup screen measured (or moved items): this is the estimate from now on.
    public func record(_ measurement: CleanupMeasurement) {
        let time = now()
        state.withLock { current in
            current.latest = measurement
            current.takenAt = time
            current.generation += 1
        }
    }

    /// True while a background measuring runs.
    var isRefreshing: Bool {
        state.withLock { $0.refreshing }
    }

    public func suggestedActions() async -> [SuggestedAction] {
        let time = now()
        let (latest, startsRefresh, generation) = state.withLock { current in
            let age = time.timeIntervalSince(current.takenAt)
            let stale = current.latest != nil && !(age >= 0 && age < Self.minimumAge)
            let starts = stale && !current.refreshing
            if starts {
                current.refreshing = true
            }
            return (current.latest, starts, current.generation)
        }
        if startsRefresh {
            Task { await self.refresh(generation: generation) }
        }
        return latest.flatMap(Self.action).map { [$0] } ?? []
    }

    private func refresh(generation: Int) async {
        let fresh = await scanner.measure()
        let time = now()
        state.withLock { current in
            current.refreshing = false
            guard current.generation == generation else { return }
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
