import Foundation
import MainternanceDomain
@testable import MainternancePresentation
import Synchronization

final class FakeQuarantine: QuarantineStoring {
    struct State {
        var stored: [QuarantineRecord] = []
        var inPlace: [QuarantineRecord] = []
        var unclaimed: [String] = []
        var quarantineError: QuarantineError?
        var restoreError: QuarantineError?
        var calls: [(path: String, signature: String)] = []
        var restoredIDs: [UUID] = []
        /// When true `restore` waits until `releaseRestore()`.
        var holdRestore = false
        /// When set, the three listing calls throw it (a quarantine list that cannot be read).
        var listError: QuarantineError?
        /// When true the next `unclaimedFiles` call (the last read of a reload) waits until `releaseUnclaimed()`.
        var holdNextUnclaimed = false
    }

    let state = Mutex(State())
    let log: CallLog
    let restoreCalls: AsyncStream<Void>
    private let restoreCallSource: AsyncStream<Void>.Continuation
    private let restoreGate: AsyncStream<Void>
    private let restoreGateSource: AsyncStream<Void>.Continuation

    init(log: CallLog = CallLog()) {
        self.log = log
        (restoreCalls, restoreCallSource) = AsyncStream.makeStream(of: Void.self)
        (restoreGate, restoreGateSource) = AsyncStream.makeStream(of: Void.self)
        (unclaimedReached, unclaimedReachedSource) = AsyncStream.makeStream(of: Void.self)
        (unclaimedGate, unclaimedGateSource) = AsyncStream.makeStream(of: Void.self)
    }

    func releaseRestore() {
        restoreGateSource.yield()
    }

    /// One value when a held `unclaimedFiles` call has been reached, and the gate that lets it go on.
    let unclaimedReached: AsyncStream<Void>
    private let unclaimedReachedSource: AsyncStream<Void>.Continuation
    private let unclaimedGate: AsyncStream<Void>
    private let unclaimedGateSource: AsyncStream<Void>.Continuation

    func releaseUnclaimed() {
        unclaimedGateSource.yield()
    }

    func configure(_ body: (inout State) -> Void) {
        state.withLock { body(&$0) }
    }

    func quarantine(path: String, signature: String) async throws -> QuarantineRecord {
        log.add("quarantine")
        return try state.withLock { current in
            current.calls.append((path, signature))
            if let error = current.quarantineError {
                throw error
            }
            let record = QuarantineRecord(
                id: UUID(), originalPath: path, quarantinedAt: Date(timeIntervalSince1970: 1_800_000_000),
                signature: signature, sha256: "00", size: 1, originalPermissions: 0o644
            )
            current.stored.append(record)
            return record
        }
    }

    func restore(_ id: UUID) async throws -> String {
        log.add("restore")
        if state.withLock({ $0.holdRestore }) {
            restoreCallSource.yield()
            for await _ in restoreGate {
                break
            }
        }
        return try state.withLock { current in
            current.restoredIDs.append(id)
            if let error = current.restoreError {
                throw error
            }
            guard let record = current.stored.first(where: { $0.id == id }) else { throw QuarantineError.missing }
            current.stored.removeAll { $0.id == id }
            return record.originalPath
        }
    }

    func records() async throws -> [QuarantineRecord] {
        try throwIfUnreadable()
        return state.withLock { $0.stored }
    }

    func stillInPlace() async throws -> [QuarantineRecord] {
        try throwIfUnreadable()
        return state.withLock { $0.inPlace }
    }

    func unclaimedFiles() async throws -> [String] {
        try throwIfUnreadable()
        let hold = state.withLock { current in
            defer { current.holdNextUnclaimed = false }
            return current.holdNextUnclaimed
        }
        if hold {
            unclaimedReachedSource.yield()
            for await _ in unclaimedGate {
                break
            }
        }
        return state.withLock { $0.unclaimed }
    }

    private func throwIfUnreadable() throws {
        if let error = state.withLock({ $0.listError }) {
            throw error
        }
    }

    var calls: [(path: String, signature: String)] {
        state.withLock { $0.calls }
    }
}
