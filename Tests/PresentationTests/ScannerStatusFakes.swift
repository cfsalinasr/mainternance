import Foundation
import MainternanceDomain
@testable import MainternancePresentation
import Synchronization

final class FakeStatusStore: ScanStatusRecording {
    struct State {
        var recorded: [(summary: ScanSummary, memory: ScanMemory)] = []
        var remembered: [ScanMemory] = []
        /// Every memory written by either call, in order.
        var memories: [ScanMemory] = []
        var stored: RecordedScanStatus?
        /// Answer `loadState` with "a file is there but unreadable".
        var unreadable = false
        /// Memories written through `rememberProgress` (the coalesced kind).
        var progress: [ScanMemory] = []
        var flushCount = 0
        /// When true the next `remember` waits until `releaseRemember()`.
        var holdNextRemember = false
    }

    let state = Mutex(State())
    /// One value per write, so a test can wait for a save without polling.
    let writes: AsyncStream<Void>
    private let writeSource: AsyncStream<Void>.Continuation

    /// One value when a held `remember` has been reached, and the gate that lets it go on.
    let rememberReached: AsyncStream<Void>
    private let rememberReachedSource: AsyncStream<Void>.Continuation
    private let rememberGate: AsyncStream<Void>
    private let rememberGateSource: AsyncStream<Void>.Continuation

    init() {
        (writes, writeSource) = AsyncStream.makeStream(of: Void.self)
        (rememberReached, rememberReachedSource) = AsyncStream.makeStream(of: Void.self)
        (rememberGate, rememberGateSource) = AsyncStream.makeStream(of: Void.self)
    }

    func releaseRemember() {
        rememberGateSource.yield()
    }

    func recordScan(_ summary: ScanSummary, memory: ScanMemory) async {
        state.withLock {
            $0.recorded.append((summary, memory))
            $0.memories.append(memory)
        }
        writeSource.yield()
    }

    func remember(_ memory: ScanMemory) async {
        let hold = state.withLock { current in
            defer { current.holdNextRemember = false }
            return current.holdNextRemember
        }
        if hold {
            rememberReachedSource.yield()
            for await _ in rememberGate {
                break
            }
        }
        state.withLock {
            $0.remembered.append(memory)
            $0.memories.append(memory)
        }
        writeSource.yield()
    }

    func rememberProgress(_ memory: ScanMemory) async {
        state.withLock {
            $0.progress.append(memory)
            $0.memories.append(memory)
        }
        writeSource.yield()
    }

    func flush() async {
        state.withLock { $0.flushCount += 1 }
    }

    func loadState() async -> ScanStatusLoad {
        state.withLock { current in
            if current.unreadable {
                return .unreadable
            }
            return current.stored.map { .saved($0) } ?? .nothingSaved
        }
    }

    func load() async -> RecordedScanStatus? {
        state.withLock { $0.stored }
    }

    var recorded: [(summary: ScanSummary, memory: ScanMemory)] {
        state.withLock { $0.recorded }
    }

    var remembered: [ScanMemory] {
        state.withLock { $0.remembered }
    }

    /// The memory most recently written by either call.
    var lastMemory: ScanMemory? {
        state.withLock { $0.memories.last }
    }
}

extension FakeStatusStore {
    /// Every memory written by either call, in order.
    var memories: [ScanMemory] {
        state.withLock { $0.memories }
    }
}
