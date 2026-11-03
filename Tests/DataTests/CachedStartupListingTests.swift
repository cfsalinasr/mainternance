import Foundation
@testable import MainternanceData
import MainternanceDomain
import Synchronization
import Testing

/// Counts how often it is asked; answers with a snapshot whose `newCount` is the call number.
private final class CountingListing: StartupListing {
    let calls = Mutex(0)

    func list() async -> StartupSnapshot {
        let call = calls.withLock { count in
            count += 1
            return count
        }
        return StartupSnapshot(baselineEstablished: true, newCount: call)
    }

    var count: Int {
        calls.withLock { $0 }
    }
}

/// Home's counter polls every few seconds; the plists are read again only when the cached answer is old enough
/// or was invalidated.
@Suite("Cached startup listing")
struct CachedStartupListingTests {
    @Test("an answer younger than the minimum age is reused; at the minimum age it is read again")
    func reusesYoungAnswers() async {
        let base = CountingListing()
        let clock = TestClock()
        let cache = CachedStartupListing(base: base, minimumAge: 60, now: clock.reading)
        #expect(await cache.list().newCount == 1)
        clock.advance(30)
        #expect(await cache.list().newCount == 1)
        clock.advance(29.5)
        #expect(await cache.list().newCount == 1)
        #expect(base.count == 1)
        clock.advance(0.5)
        #expect(await cache.list().newCount == 2)
        #expect(base.count == 2)
    }

    @Test("invalidate makes the next listing read again")
    func invalidates() async {
        let base = CountingListing()
        let cache = CachedStartupListing(base: base, minimumAge: 60, now: TestClock().reading)
        _ = await cache.list()
        cache.invalidate()
        #expect(await cache.list().newCount == 2)
        #expect(await cache.list().newCount == 2)
        #expect(base.count == 2)
    }

    @Test("a clock that went backwards never keeps an answer forever")
    func clockBackwards() async {
        let base = CountingListing()
        let clock = TestClock()
        let cache = CachedStartupListing(base: base, minimumAge: 60, now: clock.reading)
        _ = await cache.list()
        clock.advance(-120)
        #expect(await cache.list().newCount == 2)
    }
}
