import Foundation
@testable import MainternanceData
import MainternanceDomain
import Synchronization
import Testing

/// Counts measurings and returns whatever the test set; never touches the disk.
final class CountingCleanupScanner: CleanupScanning {
    private struct State {
        var count = 0
        var next: CleanupMeasurement
        var priority: TaskPriority?
    }

    private let state: Mutex<State>

    init(_ next: CleanupMeasurement) {
        state = Mutex(State(next: next))
    }

    func measure() async -> CleanupMeasurement {
        let priority = Task.currentPriority
        return state.withLock { current in
            current.count += 1
            current.priority = priority
            return current.next
        }
    }

    /// The priority the last measuring ran at.
    var priority: TaskPriority? {
        state.withLock { $0.priority }
    }

    func setNext(_ measurement: CleanupMeasurement) {
        state.withLock { $0.next = measurement }
    }

    var count: Int {
        state.withLock { $0.count }
    }
}

/// A clock the test moves by hand.
final class ManualClock: Sendable {
    private let time = Mutex(Date(timeIntervalSince1970: 1_800_000_000))

    func now() -> Date {
        time.withLock { $0 }
    }

    func advance(_ seconds: TimeInterval) {
        time.withLock { $0 = $0.addingTimeInterval(seconds) }
    }
}

/// A switch the test flips by hand (Low Power Mode).
final class ManualFlag: Sendable {
    private let value = Mutex(false)

    func get() -> Bool {
        value.withLock { $0 }
    }

    func set(_ flag: Bool) {
        value.withLock { $0 = flag }
    }
}

@Suite("Cleanup estimate on Home")
struct CleanupEstimateTests {
    private static func measurement(_ bytes: Int64, lowerBound: Bool = false) -> CleanupMeasurement {
        let entry = CleanupEntry(
            path: "/Users/me/Library/Caches/a", bytes: bytes, isLowerBound: lowerBound, type: .directory,
            modified: nil
        )
        return CleanupMeasurement(
            categories: [CleanupCategory(kind: .caches, entries: [entry])], measuredAt: Date(timeIntervalSince1970: 0)
        )
    }

    private struct Rig {
        let estimate: CleanupEstimate
        let scanner: CountingCleanupScanner
        let clock: ManualClock
        let lowPower: ManualFlag
    }

    /// An estimate with Home on screen and Low Power Mode off, unless the test changes them.
    private func rig(_ next: CleanupMeasurement = measurement(0)) -> Rig {
        let scanner = CountingCleanupScanner(next)
        let clock = ManualClock()
        let lowPower = ManualFlag()
        let estimate = CleanupEstimate(scanner: scanner, now: { clock.now() }, isLowPowerMode: { lowPower.get() })
        estimate.setHomeVisible(true)
        return Rig(estimate: estimate, scanner: scanner, clock: clock, lowPower: lowPower)
    }

    private struct GatedRig {
        let estimate: CleanupEstimate
        let gate: GatedEstimateScanner
        let clock: ManualClock
    }

    /// A visible estimate over a measurer that waits for the test, already holding a stale 1 GB measurement.
    private func gatedRig() -> GatedRig {
        let gate = GatedEstimateScanner()
        let clock = ManualClock()
        let estimate = CleanupEstimate(scanner: gate, now: { clock.now() }, isLowPowerMode: { false })
        estimate.setHomeVisible(true)
        estimate.record(Self.measurement(1_000_000_000))
        clock.advance(601)
        return GatedRig(estimate: estimate, gate: gate, clock: clock)
    }

    /// Waits until the estimate's background measuring (if any) has finished.
    private func settle(_ estimate: CleanupEstimate) async {
        while estimate.isRefreshing {
            await Task.yield()
        }
    }

    @Test("nothing is suggested, and nothing measured, until a first measurement exists")
    func noneUntilMeasured() async {
        let parts = rig(Self.measurement(9_000_000_000))
        let (estimate, scanner, clock) = (parts.estimate, parts.scanner, parts.clock)
        #expect(await estimate.suggestedActions().isEmpty)
        clock.advance(3600)
        #expect(await estimate.suggestedActions().isEmpty)
        await settle(estimate)
        #expect(scanner.count == 0) // Home never starts the first disk walk
    }

    @Test("a measurement of at least 500 MB becomes one suggestion that opens Cleanup")
    func suggestsAtThreshold() async throws {
        let estimate = rig().estimate
        estimate.record(Self.measurement(12_000_000_000))
        let action = try #require(await estimate.suggestedActions().first)
        #expect(await estimate.suggestedActions().count == 1)
        #expect(action.title == "Free about 12 GB in Cleanup")
        #expect(action.destination == .cleanup)
        #expect(action.id == "cleanup")
        #expect(action.detail == "Caches to review. They move to the Trash, never deleted.") // only caches here
        estimate.record(Self.measurement(500_000_000))
        #expect(await estimate.suggestedActions().count == 1)
        estimate.record(Self.measurement(499_999_999))
        #expect(await estimate.suggestedActions().isEmpty)
    }

    @Test("the detail names only the categories that hold something")
    func detailNamesPresentCategories() {
        func category(_ kind: CleanupKind, _ bytes: Int64) -> CleanupCategory {
            CleanupCategory(kind: kind, entries: [CleanupEntry(
                path: "/Users/me/x/\(kind.rawValue)", bytes: bytes, isLowerBound: false, type: .directory, modified: nil
            )])
        }
        #expect(CleanupEstimate.present([category(.caches, 1)]) == "Caches")
        #expect(CleanupEstimate.present([category(.logs, 1), category(.developer, 1)]) == "Logs and build caches")
        #expect(CleanupEstimate.present([category(.caches, 1), category(.logs, 0), category(.developer, 1)])
            == "Caches and build caches")
        #expect(CleanupEstimate.present([category(.caches, 1), category(.logs, 1), category(.developer, 1)])
            == "Caches, logs and build caches")
    }

    @Test("old installers (never ticked by default) are not in the headline, only mentioned on their own")
    func installersMentionedSeparately() async throws {
        let estimate = rig().estimate
        let installer = CleanupEntry(
            path: "/Users/me/Downloads/Old.dmg", bytes: 6_000_000_000, isLowerBound: false, type: .file, modified: nil
        )
        var measurement = Self.measurement(1_000_000_000)
        measurement.categories.append(CleanupCategory(kind: .installers, entries: [installer]))
        estimate.record(measurement)
        let action = try #require(await estimate.suggestedActions().first)
        #expect(action.title == "Free about 1 GB in Cleanup")
        #expect(action.detail == "Caches to review. They move to the Trash, never deleted."
            + " Also about 6 GB of old installers, not selected until you tick them.")
        // Only installers worth mentioning: the suggestion says to review them, never "free".
        var onlyInstallers = Self.measurement(100_000_000)
        onlyInstallers.categories.append(CleanupCategory(kind: .installers, entries: [installer]))
        estimate.record(onlyInstallers)
        let review = try #require(await estimate.suggestedActions().first)
        #expect(review.title == "Review about 6 GB of old installers in Cleanup")
        #expect(review.destination == .cleanup)
    }

    @Test("a lower-bound total says at least")
    func lowerBound() async throws {
        let estimate = rig().estimate
        estimate.record(Self.measurement(2_000_000_000, lowerBound: true))
        let action = try #require(await estimate.suggestedActions().first)
        #expect(action.title == "Free at least 2 GB in Cleanup")
    }

    @Test("the estimate is measured again at most every 10 minutes, in the background")
    func refreshesAtMostEveryTenMinutes() async {
        let parts = rig(Self.measurement(3_000_000_000))
        let (estimate, scanner, clock) = (parts.estimate, parts.scanner, parts.clock)
        estimate.record(Self.measurement(1_000_000_000))
        clock.advance(599)
        #expect(await estimate.suggestedActions().first?.title == "Free about 1 GB in Cleanup")
        await settle(estimate)
        #expect(scanner.count == 0)
        clock.advance(1)
        // The stale answer is returned at once; the new one arrives once the background measuring finished.
        #expect(await estimate.suggestedActions().first?.title == "Free about 1 GB in Cleanup")
        await settle(estimate)
        #expect(scanner.count == 1)
        #expect(await estimate.suggestedActions().first?.title == "Free about 3 GB in Cleanup")
        clock.advance(300)
        _ = await estimate.suggestedActions()
        await settle(estimate)
        #expect(scanner.count == 1)
    }

    @Test("a measurement from the Cleanup screen replaces the estimate at once")
    func recordUpdatesImmediately() async {
        let parts = rig()
        let (estimate, scanner) = (parts.estimate, parts.scanner)
        estimate.record(Self.measurement(5_000_000_000))
        #expect(await estimate.suggestedActions().first?.title == "Free about 5 GB in Cleanup")
        estimate.record(Self.measurement(100_000_000)) // after a move: below the threshold
        #expect(await estimate.suggestedActions().isEmpty)
        #expect(scanner.count == 0)
    }

    @Test("a clock that went backwards counts as stale")
    func clockBackwards() async {
        let parts = rig(Self.measurement(3_000_000_000))
        let (estimate, scanner, clock) = (parts.estimate, parts.scanner, parts.clock)
        estimate.record(Self.measurement(1_000_000_000))
        clock.advance(-60)
        _ = await estimate.suggestedActions()
        await settle(estimate)
        #expect(scanner.count == 1)
    }

    @Test("a background measuring that finishes after a newer screen measurement is dropped")
    func olderBackgroundResultDropped() async {
        let rig = gatedRig()
        let (estimate, gate) = (rig.estimate, rig.gate)
        _ = await estimate.suggestedActions()
        await gate.waitForCall()
        estimate.record(Self.measurement(7_000_000_000))
        gate.release(Self.measurement(2_000_000_000))
        await settle(estimate)
        #expect(await estimate.suggestedActions().first?.title == "Free about 7 GB in Cleanup")
    }

    @Test("nothing is measured while Home is not on screen; it measures again once Home shows")
    func onlyWhileHomeVisible() async {
        let parts = rig(Self.measurement(3_000_000_000))
        let (estimate, scanner, clock) = (parts.estimate, parts.scanner, parts.clock)
        estimate.record(Self.measurement(1_000_000_000))
        estimate.setHomeVisible(false)
        clock.advance(3600)
        for _ in 0 ..< 3 {
            #expect(await estimate.suggestedActions().first?.title == "Free about 1 GB in Cleanup")
        }
        await settle(estimate)
        #expect(scanner.count == 0)
        estimate.setHomeVisible(true)
        _ = await estimate.suggestedActions()
        await settle(estimate)
        #expect(scanner.count == 1)
    }

    @Test("nothing is measured in Low Power Mode")
    func skippedInLowPowerMode() async {
        let parts = rig(Self.measurement(3_000_000_000))
        let (estimate, scanner, clock) = (parts.estimate, parts.scanner, parts.clock)
        estimate.record(Self.measurement(1_000_000_000))
        parts.lowPower.set(true)
        clock.advance(3600)
        #expect(await estimate.suggestedActions().first?.title == "Free about 1 GB in Cleanup")
        await settle(estimate)
        #expect(scanner.count == 0)
        parts.lowPower.set(false)
        _ = await estimate.suggestedActions()
        await settle(estimate)
        #expect(scanner.count == 1)
    }

    @Test("the background measuring runs at background priority")
    func backgroundPriority() async {
        let parts = rig(Self.measurement(3_000_000_000))
        parts.estimate.record(Self.measurement(1_000_000_000))
        parts.clock.advance(601)
        _ = await parts.estimate.suggestedActions()
        await settle(parts.estimate)
        #expect(parts.scanner.priority == .background)
    }

    @Test("Home going off screen cancels a running measuring; its result is dropped")
    func hidingCancels() async {
        let rig = gatedRig()
        let (estimate, gate) = (rig.estimate, rig.gate)
        _ = await estimate.suggestedActions()
        await gate.waitForCall()
        estimate.setHomeVisible(false)
        gate.release(Self.measurement(9_000_000_000))
        await settle(estimate)
        #expect(await estimate.suggestedActions().first?.title == "Free about 1 GB in Cleanup")
    }

    @Test("two measurings never overlap, even when a cancelled one has not finished yet")
    func neverOverlaps() async {
        let rig = gatedRig()
        let (estimate, gate) = (rig.estimate, rig.gate)
        _ = await estimate.suggestedActions()
        await gate.waitForCall()
        _ = await estimate.suggestedActions()
        estimate.setHomeVisible(false) // cancelled, but still winding down
        estimate.setHomeVisible(true)
        _ = await estimate.suggestedActions()
        #expect(gate.waitingCount == 1)
        gate.release(Self.measurement(9_000_000_000))
        await settle(estimate)
        #expect(gate.waitingCount == 0)
        _ = await estimate.suggestedActions() // the cancelled one ended: a new one may start
        await gate.waitForCall()
        gate.release(Self.measurement(4_000_000_000))
        await settle(estimate)
        #expect(await estimate.suggestedActions().first?.title == "Free about 4 GB in Cleanup")
    }

    @Test("a finished background measuring replaces the estimate, even when it is smaller")
    func smallerTotalReplaces() async {
        let parts = rig(Self.measurement(100_000_000))
        parts.estimate.record(Self.measurement(5_000_000_000))
        parts.clock.advance(601)
        _ = await parts.estimate.suggestedActions()
        await settle(parts.estimate)
        // The owner emptied caches elsewhere: the smaller, newer total is the truth, and below 500 MB nothing shows.
        #expect(await parts.estimate.suggestedActions().isEmpty)
    }

    @Test("a background measuring that did not finish (cancelled) keeps the previous estimate")
    func unfinishedKeepsEstimate() async {
        let rig = gatedRig()
        let (estimate, gate) = (rig.estimate, rig.gate)
        _ = await estimate.suggestedActions()
        await gate.waitForCall()
        estimate.setHomeVisible(false)
        gate.release(CleanupMeasurement(categories: [], measuredAt: Date(timeIntervalSince1970: 0)))
        await settle(estimate)
        #expect(await estimate.suggestedActions().first?.title == "Free about 1 GB in Cleanup")
    }
}

/// A measurer whose single measuring waits until the test releases it.
final class GatedEstimateScanner: CleanupScanning {
    private let waiting = Mutex<[CheckedContinuation<CleanupMeasurement, Never>]>([])

    func measure() async -> CleanupMeasurement {
        await withCheckedContinuation { continuation in
            waiting.withLock { $0.append(continuation) }
        }
    }

    func waitForCall() async {
        while waiting.withLock({ $0.isEmpty }) {
            await Task.yield()
        }
    }

    var waitingCount: Int {
        waiting.withLock { $0.count }
    }

    func release(_ measurement: CleanupMeasurement) {
        let next = waiting.withLock { $0.isEmpty ? nil : $0.removeFirst() }
        next?.resume(returning: measurement)
    }
}
