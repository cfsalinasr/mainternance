import Foundation
import MainternanceDomain
@testable import MainternancePresentation
import Synchronization

/// Stands in for the Data layer's measurer and mover: returns a scripted measurement and records every move. Real
/// Domain types throughout; nothing touches the disk.
final class FakeCleanup: CleanupScanning, CleanupMoving {
    struct State {
        var measurement: CleanupMeasurement
        var measures = 0
        var moves: [[String]] = []
        /// Entry ids that fail to move, with their reason.
        var failing: [String: String] = [:]
    }

    let state: Mutex<State>

    init(_ measurement: CleanupMeasurement = CleanupRig.sample) {
        state = Mutex(State(measurement: measurement))
    }

    func configure(_ body: (inout State) -> Void) {
        state.withLock { body(&$0) }
    }

    func measure() async -> CleanupMeasurement {
        state.withLock { current in
            current.measures += 1
            return current.measurement
        }
    }

    func moveToTrash(_ entries: [CleanupEntry]) async -> CleanupOutcome {
        state.withLock { current in
            current.moves.append(entries.map(\.id))
            let failed = entries.compactMap { entry in
                current.failing[entry.id].map { CleanupFailure(entry: entry, reason: $0) }
            }
            let moved = entries.filter { current.failing[$0.id] == nil }
            return CleanupOutcome(moved: moved, failed: failed)
        }
    }

    var measures: Int {
        state.withLock { $0.measures }
    }

    var moves: [[String]] {
        state.withLock { $0.moves }
    }
}

/// Calls that wait until the test releases them, by position (0 is the oldest still waiting).
final class Gate<Value: Sendable>: Sendable {
    private let waiting = Mutex<[CheckedContinuation<Value, Never>]>([])

    func wait() async -> Value {
        await withCheckedContinuation { continuation in
            waiting.withLock { $0.append(continuation) }
        }
    }

    /// Returns once at least `count` calls are waiting.
    func waitForCall(_ count: Int = 1) async {
        while waiting.withLock({ $0.count < count }) {
            await Task.yield()
        }
    }

    func release(_ value: Value, at index: Int = 0) {
        let next = waiting.withLock { $0.indices.contains(index) ? $0.remove(at: index) : nil }
        next?.resume(returning: value)
    }
}

/// A measurer whose measurings wait until the test releases them.
final class GatedCleanupScanner: CleanupScanning {
    let gate = Gate<CleanupMeasurement>()

    func measure() async -> CleanupMeasurement {
        await gate.wait()
    }

    func waitForCall(_ count: Int = 1) async {
        await gate.waitForCall(count)
    }

    func release(_ measurement: CleanupMeasurement, at index: Int = 0) {
        gate.release(measurement, at: index)
    }
}

/// A mover whose move waits until the test releases it.
final class GatedMover: CleanupMoving {
    let gate = Gate<CleanupOutcome>()

    func moveToTrash(_: [CleanupEntry]) async -> CleanupOutcome {
        await gate.wait()
    }

    func waitForCall() async {
        await gate.waitForCall()
    }

    func release(_ outcome: CleanupOutcome) {
        gate.release(outcome)
    }
}

/// A clock the test moves by hand.
final class CleanupClock: Sendable {
    private let time = Mutex(Date(timeIntervalSince1970: 1_800_000_000))

    func now() -> Date {
        time.withLock { $0 }
    }

    func advance(_ seconds: TimeInterval) {
        time.withLock { $0 = $0.addingTimeInterval(seconds) }
    }
}

/// A Cleanup screen state over a `FakeCleanup` and a hand-moved clock, recording every measurement it reports.
@MainActor
struct CleanupRig {
    let fake: FakeCleanup
    let clock = CleanupClock()
    let reported = Recorded<CleanupMeasurement>()
    let state: CleanupViewState

    init(_ measurement: CleanupMeasurement = CleanupRig.sample, scanner: (any CleanupScanning)? = nil) {
        let fake = FakeCleanup(measurement)
        self.fake = fake
        let clock = clock
        state = CleanupViewState(scanner: scanner ?? fake, mover: fake, now: { clock.now() })
        let reported = reported
        state.onMeasurement = { reported.add($0) }
    }

    nonisolated static let megabyte: Int64 = 1_000_000

    nonisolated static func entry(
        _ name: String, _ megabytes: Int64, folder: String = "/Users/me/Library/Caches", lowerBound: Bool = false
    ) -> CleanupEntry {
        CleanupEntry(
            path: "\(folder)/\(name)", bytes: megabytes * megabyte, isLowerBound: lowerBound, type: .directory,
            modified: nil
        )
    }

    nonisolated static func path(_ name: String, folder: String = "/Users/me/Library/Caches") -> String {
        "\(folder)/\(name)"
    }

    nonisolated static let downloads = "/Users/me/Downloads"

    /// The sample plus one old installer of 700 MB.
    nonisolated static var withInstaller: CleanupMeasurement {
        var measurement = sample
        measurement.categories.append(
            CleanupCategory(kind: .installers, entries: [entry("Old.dmg", 700, folder: downloads)])
        )
        return measurement
    }

    /// Caches 3.2 GB in two entries, logs 50 MB in one.
    nonisolated static var sample: CleanupMeasurement {
        CleanupMeasurement(
            categories: [
                CleanupCategory(kind: .caches, entries: [entry("big", 3000), entry("small", 200)]),
                CleanupCategory(kind: .logs, entries: [entry("app.log", 50, folder: "/Users/me/Library/Logs")])
            ],
            measuredAt: Date(timeIntervalSince1970: 1_800_000_000)
        )
    }
}
