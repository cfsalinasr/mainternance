import Foundation
import MainternanceDomain
@testable import MainternancePresentation
import Synchronization

/// Shared, ordered record of calls across fakes, to prove "verify before quarantine".
final class CallLog: Sendable {
    private let entries = Mutex<[String]>([])

    func add(_ entry: String) {
        entries.withLock { $0.append(entry) }
    }

    var all: [String] {
        entries.withLock { $0 }
    }
}

final class FakeEngine: ScannerEngine {
    struct State {
        var status: EngineStatus = .ready(definitionsAge: 60)
        var installEvents: [InstallEvent] = [.finished]
        var updateEvents: [InstallEvent] = [.finished]
        var scanEvents: [ScanEvent] = []
        /// When true the scan stream stays open until `emit`/`finishScan` or `cancelScan`.
        var holdScan = false
        var statusAfterInstall: EngineStatus?
        var statusAfterUpdate: EngineStatus?
        var verify: [String: VerifyResult] = [:]
        var verifyDefault: VerifyResult = .failed(message: "not scripted")
        var scans: [ScanScope] = []
        var verified: [String] = []
        var cancelCalls = 0
        var cancelSummary: ScanSummary?
        var heldContinuation: AsyncStream<ScanEvent>.Continuation?
        /// Folders each scope walks; paths under `excluded` are skipped. Unknown scopes cover nothing.
        var roots: [ScanScope: [String]] = [
            .quick: ["/Users/someone/Downloads", "/Users/someone/Desktop", "/Applications"],
            .full: ["/Users/someone", "/Applications"]
        ]
        var excluded: [ScanScope: [String]] = [
            .full: ["/Users/someone/Library/Mobile Documents", "/Users/someone/Library/CloudStorage"]
        ]
        /// When true the install stream stays open until `emitInstall`/`finishInstall`.
        var holdInstall = false
        var heldInstall: AsyncStream<InstallEvent>.Continuation?
    }

    let state = Mutex(State())
    let log: CallLog
    let scanCalls: AsyncStream<Void>
    private let scanCallSource: AsyncStream<Void>.Continuation
    let installCalls: AsyncStream<Void>
    private let installCallSource: AsyncStream<Void>.Continuation

    init(log: CallLog = CallLog()) {
        self.log = log
        (scanCalls, scanCallSource) = AsyncStream.makeStream(of: Void.self)
        (installCalls, installCallSource) = AsyncStream.makeStream(of: Void.self)
    }

    func configure(_ body: (inout State) -> Void) {
        state.withLock { body(&$0) }
    }

    func status() async -> EngineStatus {
        state.withLock { $0.status }
    }

    func install() -> AsyncStream<InstallEvent> {
        if state.withLock({ $0.holdInstall }) {
            return AsyncStream { continuation in
                state.withLock { $0.heldInstall = continuation }
                installCallSource.yield()
            }
        }
        return replay(state.withLock { ($0.installEvents, $0.statusAfterInstall) })
    }

    func emitInstall(_ event: InstallEvent) {
        let continuation = state.withLock { $0.heldInstall }
        continuation?.yield(event)
    }

    func finishInstall() {
        let continuation = state.withLock { $0.heldInstall }
        continuation?.finish()
    }

    func updateDefinitions() -> AsyncStream<InstallEvent> {
        replay(state.withLock { ($0.updateEvents, $0.statusAfterUpdate) })
    }

    private func replay(_ script: ([InstallEvent], EngineStatus?)) -> AsyncStream<InstallEvent> {
        let (events, after) = script
        return AsyncStream { continuation in
            for event in events {
                continuation.yield(event)
            }
            if let after {
                state.withLock { $0.status = after }
            }
            continuation.finish()
        }
    }

    func scan(_ scope: ScanScope) -> AsyncStream<ScanEvent> {
        let (events, hold) = state.withLock { current -> ([ScanEvent], Bool) in
            current.scans.append(scope)
            return (current.scanEvents, current.holdScan)
        }
        log.add("scan")
        scanCallSource.yield()
        return AsyncStream { continuation in
            for event in events {
                continuation.yield(event)
            }
            if hold {
                state.withLock { $0.heldContinuation = continuation }
            } else {
                continuation.finish()
            }
        }
    }

    func emit(_ event: ScanEvent) {
        let continuation = state.withLock { $0.heldContinuation }
        continuation?.yield(event)
    }

    func finishScan() {
        let continuation = state.withLock { current -> AsyncStream<ScanEvent>.Continuation? in
            defer { current.heldContinuation = nil }
            return current.heldContinuation
        }
        continuation?.finish()
    }

    func verifyFinding(path: String) async -> VerifyResult {
        log.add("verify")
        return state.withLock { current in
            current.verified.append(path)
            return current.verify[path] ?? current.verifyDefault
        }
    }

    func coverage(of scope: ScanScope) -> ScanCoverage {
        state.withLock { ScanCoverage(roots: $0.roots[scope] ?? [], excluded: $0.excluded[scope] ?? []) }
    }

    func cancelScan() async {
        let (continuation, summary) = state.withLock { current -> (
            AsyncStream<ScanEvent>.Continuation?,
            ScanSummary?
        ) in
            current.cancelCalls += 1
            return (current.heldContinuation, current.cancelSummary)
        }
        if let summary {
            continuation?.yield(.finished(summary))
        }
        continuation?.finish()
    }

    var scans: [ScanScope] {
        state.withLock { $0.scans }
    }

    var verified: [String] {
        state.withLock { $0.verified }
    }
}

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
    }

    func releaseRestore() {
        restoreGateSource.yield()
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

    func records() async -> [QuarantineRecord] {
        state.withLock { $0.stored }
    }

    func stillInPlace() async -> [QuarantineRecord] {
        state.withLock { $0.inPlace }
    }

    func unclaimedFiles() async -> [String] {
        state.withLock { $0.unclaimed }
    }

    var calls: [(path: String, signature: String)] {
        state.withLock { $0.calls }
    }
}

final class FakeStatusStore: ScanStatusRecording {
    struct State {
        var recorded: [(summary: ScanSummary, memory: ScanMemory)] = []
        var remembered: [ScanMemory] = []
        /// Every memory written by either call, in order.
        var memories: [ScanMemory] = []
        var stored: RecordedScanStatus?
    }

    let state = Mutex(State())

    func recordScan(_ summary: ScanSummary, memory: ScanMemory) async {
        state.withLock {
            $0.recorded.append((summary, memory))
            $0.memories.append(memory)
        }
    }

    func remember(_ memory: ScanMemory) async {
        state.withLock {
            $0.remembered.append(memory)
            $0.memories.append(memory)
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

final class OpenedURLs: Sendable {
    private let urls = Mutex<[URL]>([])

    func add(_ url: URL) {
        urls.withLock { $0.append(url) }
    }

    var all: [URL] {
        urls.withLock { $0 }
    }
}

let testNow = Date(timeIntervalSince1970: 1_800_000_000)

func makeFinding(_ index: Int, signature: String = "Win.Test.EICAR_HDB-1", path: String? = nil) -> ScanFinding {
    ScanFinding(
        id: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", index)) ?? UUID(),
        path: path ?? "/Users/someone/Downloads/file\(index).bin", signature: signature, foundAt: testNow
    )
}

func makeSummary(
    scope: ScanScope = .quick, scanned: Int = 100, unreadable: Int = 0, denied: Int = 0, findings: Int = 0,
    unattributed: Int = 0, cancelled: Bool = false, definitions: Date? = Date(timeIntervalSince1970: 1_799_900_000)
) -> ScanSummary {
    ScanSummary(
        scope: scope, scanned: scanned, unreadable: unreadable, findings: findings,
        startedAt: testNow, endedAt: testNow.addingTimeInterval(30), cancelled: cancelled,
        definitionsDate: definitions, permissionDenied: denied, unattributedDetections: unattributed
    )
}

@MainActor
struct ScannerRig {
    let engine: FakeEngine
    let quarantine: FakeQuarantine
    let store: FakeStatusStore
    let opened: OpenedURLs
    let log: CallLog
    let model: ScannerViewModel

    init(protectedFolders: [URL] = []) {
        let log = CallLog()
        let engine = FakeEngine(log: log)
        let quarantine = FakeQuarantine(log: log)
        let store = FakeStatusStore()
        let opened = OpenedURLs()
        self.log = log
        self.engine = engine
        self.quarantine = quarantine
        self.store = store
        self.opened = opened
        model = ScannerViewModel(
            engine: engine, quarantine: quarantine, statusStore: store, protectedFolders: protectedFolders,
            openURL: { opened.add($0) }
        )
    }

    /// A rig whose model already checked the engine status.
    static func ready(protectedFolders: [URL] = []) async -> ScannerRig {
        let rig = ScannerRig(protectedFolders: protectedFolders)
        await rig.model.refreshStatus()
        return rig
    }

    /// Runs a scan of `scope` that reports `findings` and then finishes.
    func scanFinding(_ findings: [ScanFinding], scope: ScanScope = .quick) async {
        engine.configure {
            $0.scanEvents = [.started(scope: scope)] + findings.map { .found($0) }
                + [.finished(makeSummary(scope: scope, findings: findings.count))]
        }
        await model.startScan(scope)
    }
}

extension ScannerViewModel {
    /// Waits (without polling) until `predicate` holds for this model, or fails after 10 s instead of hanging.
    func wait(until predicate: @escaping @MainActor () -> Bool) async -> Bool {
        if predicate() {
            return true
        }
        let watcher = Task { @MainActor in
            for await holds in Observations({ predicate() }) where holds {
                return true
            }
            return false
        }
        let timeout = Task {
            try? await Task.sleep(for: .seconds(10))
            watcher.cancel()
        }
        let result = await watcher.value
        timeout.cancel()
        return result
    }
}
