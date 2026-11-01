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
    }

    let state = Mutex(State())
    /// One value per write, so a test can wait for a save without polling.
    let writes: AsyncStream<Void>
    private let writeSource: AsyncStream<Void>.Continuation

    init() {
        (writes, writeSource) = AsyncStream.makeStream(of: Void.self)
    }

    func recordScan(_ summary: ScanSummary, memory: ScanMemory) async {
        state.withLock {
            $0.recorded.append((summary, memory))
            $0.memories.append(memory)
        }
        writeSource.yield()
    }

    func remember(_ memory: ScanMemory) async {
        state.withLock {
            $0.remembered.append(memory)
            $0.memories.append(memory)
        }
        writeSource.yield()
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
