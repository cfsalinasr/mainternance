import Foundation
import MainternanceDomain
import Synchronization

/// Reuses another lister's answer while it is younger than `minimumAge`, so Home's frequent polls do not read every
/// launchd property list each time. `invalidate()` makes the next listing read again; an answer that was being read
/// while it was invalidated is returned to its caller but not kept. A clock that went backwards counts as stale.
final class CachedStartupListing: StartupListing, Sendable {
    private struct Cache {
        var snapshot: StartupSnapshot?
        var takenAt = Date.distantPast
        var generation = 0
    }

    private let base: any StartupListing
    private let minimumAge: TimeInterval
    private let now: @Sendable () -> Date
    private let cache = Mutex(Cache())

    init(base: any StartupListing, minimumAge: TimeInterval, now: @escaping @Sendable () -> Date) {
        self.base = base
        self.minimumAge = minimumAge
        self.now = now
    }

    func list() async -> StartupSnapshot {
        let time = now()
        let (kept, generation) = cache.withLock { current -> (StartupSnapshot?, Int) in
            let age = time.timeIntervalSince(current.takenAt)
            return (age >= 0 && age < minimumAge ? current.snapshot : nil, current.generation)
        }
        if let kept {
            return kept
        }
        let fresh = await base.list()
        cache.withLock { current in
            guard current.generation == generation else { return }
            current.snapshot = fresh
            current.takenAt = time
        }
        return fresh
    }

    func invalidate() {
        cache.withLock { current in
            current.snapshot = nil
            current.generation += 1
        }
    }
}
