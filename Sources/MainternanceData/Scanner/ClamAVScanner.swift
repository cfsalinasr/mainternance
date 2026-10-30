import Foundation
import MainternanceDomain
import Synchronization

/// Running totals of one scan, fed one parsed line at a time. Pure, so the counting rules are easy to pin.
struct ScanTally {
    private(set) var scanned = 0
    private(set) var unreadable = 0
    private(set) var permissionDenied = 0
    private(set) var findings = 0
    private(set) var current = ""
    /// A stderr `ERROR:` line (clamscan's fatal messages, for example a database problem) was seen.
    private(set) var fatalSeen = false
    private var unreadablePaths = Set<String>()
    private var reportedScanned = 0
    private var lastProgressAt: Date?

    static let maxTrackedPaths = 10000

    mutating func noteFatal() {
        fatalSeen = true
    }

    /// clamscan exited 2: per upstream, exit 2 without findings only comes from counted errors (`info.errors`) or
    /// a fatal start-up problem, so a scan that exits 2 never reports zero unreadable files. When no line named
    /// the failing file (for example an allocation failure), one unattributed error is recorded.
    mutating func noteExitTwo() {
        if unreadable == 0 {
            unreadable = 1
        }
    }

    /// Counts the line and returns the finding, if the line was one. FOUND files count as scanned; unreadable
    /// files are never scanned and never clean.
    mutating func consume(_ line: ClamLine) -> (path: String, signature: String)? {
        switch line {
        case let .scanned(path):
            scanned += 1
            current = path
        case let .found(path, signature):
            scanned += 1
            findings += 1
            current = path
            return (path, signature)
        case let .unreadable(path, isPermission):
            // One entry per path, whatever number of messages clamscan printed for it. Past the cap the set stops
            // growing (bounded memory) and every further line is counted.
            if unreadablePaths.contains(path) {
                break
            }
            if unreadablePaths.count < Self.maxTrackedPaths {
                unreadablePaths.insert(path)
            }
            unreadable += 1
            if isPermission {
                permissionDenied += 1
            }
        case .ignored:
            break
        }
        return nil
    }

    /// A progress event when at least `interval` seconds passed since the last one (the first is immediate).
    mutating func throttledProgress(now: Date, interval: TimeInterval) -> ScanEvent? {
        guard scanned > reportedScanned else { return nil }
        if let last = lastProgressAt, now.timeIntervalSince(last) < interval, now >= last {
            return nil
        }
        return progressNow(now: now)
    }

    /// The closing progress event, nil when the last one already carried the final count.
    mutating func finalProgress(now: Date) -> ScanEvent? {
        scanned > reportedScanned ? progressNow(now: now) : nil
    }

    private mutating func progressNow(now: Date) -> ScanEvent {
        reportedScanned = scanned
        lastProgressAt = now
        return .progress(scanned: scanned, current: current)
    }
}

/// Runs `clamscan` over a scope and turns its output into `ScanEvent`s.
///
/// Only the located `clamscan` is run, with an argument array (no shell, never `sudo`), at low priority, against
/// the app-owned definitions. Roots are absolute paths placed after `--`, so a folder named like an option is data.
/// One scan runs at a time. Quitting: the app target MUST call `terminateNow()` (and the installer's) from
/// `applicationWillTerminate`, otherwise a running `clamscan` outlives the app.
///
/// Exit codes (upstream `clamscan/manager.c`, end of `scanmanager`: infection first, then errors):
/// 0 clean, and 1 infected files found, both end in `.finished` (exit 1 keeps the counts even when unreadable files
/// were also met). Exit 2 means errors and NO infection: with files scanned and no fatal `ERROR:` line it is a
/// partial scan (typically no Full Disk Access) and ends in `.finished` with the unreadable counts, never zero;
/// with nothing scanned or a fatal line it ends in `.failed`. Any other code is `.failed`. The Domain has no
/// failure-note field on a finished scan, so a failure after findings is delivered as `.failed` AFTER the `.found`
/// events, which stay valid (see `ScanEvent`).
public final class ClamAVScanner: ScannerEngine {
    static let progressInterval: TimeInterval = 0.1
    static let busyMessage = "A scan is already running"

    private struct State {
        var busy = false
        var current: RunningProcess?
        var cancelRequested = false
        var quitRequested = false
    }

    private let locator: ToolLocator
    private let runner: ProcessRunning
    private let paths: ClamAVPaths
    private let definitions: DefinitionsStore
    private let installer: ClamAVInstaller
    private let now: @Sendable () -> Date
    private let home: URL
    private let state = Mutex(State())

    public init(
        locator: ToolLocator,
        runner: ProcessRunning,
        paths: ClamAVPaths,
        definitions: DefinitionsStore,
        installer: ClamAVInstaller,
        now: @escaping @Sendable () -> Date = { Date() },
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) {
        self.locator = locator
        self.runner = runner
        self.paths = paths
        self.definitions = definitions
        self.installer = installer
        self.now = now
        self.home = home
    }

    public func status() async -> EngineStatus {
        status(definitionsDate: definitions.definitionsDate())
    }

    public func install() -> AsyncStream<InstallEvent> {
        installer.install()
    }

    public func updateDefinitions() -> AsyncStream<InstallEvent> {
        installer.updateDefinitions()
    }

    private func status(definitionsDate: Date?) -> EngineStatus {
        EngineStatus.status(
            engineInstalled: installer.isInstalled(),
            homebrewAvailable: locator.path(for: "brew") != nil,
            definitionsDate: definitionsDate,
            now: now()
        )
    }

    /// Stops the running scan: its `clamscan` group is terminated and the stream ends with `.finished` whose
    /// summary has `cancelled == true` (counts so far preserved). A no-op when no scan runs.
    public func cancelScan() async {
        let process = state.withLock { current -> RunningProcess? in
            guard current.busy else { return nil }
            current.cancelRequested = true
            return current.current
        }
        await process?.terminate(killGroup: true)
    }

    /// Synchronous, idempotent quit hook: SIGKILLs the running `clamscan` group and forbids any later start, even
    /// one that is about to launch (the flag is checked in the same critical section that starts the child).
    public func terminateNow() {
        let process = state.withLock { current -> RunningProcess? in
            current.quitRequested = true
            return current.current
        }
        process?.terminateNow()
    }

    public func scan(_ scope: ScanScope) -> AsyncStream<ScanEvent> {
        let claimed = state.withLock { current -> Bool in
            guard !current.busy else { return false }
            current.busy = true
            current.cancelRequested = false
            return true
        }
        return AsyncStream { continuation in
            guard claimed else {
                continuation.yield(.failed(message: Self.busyMessage))
                continuation.finish()
                return
            }
            let task = Task { [self] in
                let last = await execute(scope, continuation)
                // Release before the terminal event, so a consumer that reacts to it can start the next scan.
                state.withLock {
                    $0.busy = false
                    $0.current = nil
                }
                continuation.yield(last)
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Running a scan

    /// Everything up to and including the terminal event, which is returned (not yielded).
    private func execute(_ scope: ScanScope, _ continuation: AsyncStream<ScanEvent>.Continuation) async -> ScanEvent {
        let definitionsDate = definitions.definitionsDate()
        if let reason = Self.refusal(status(definitionsDate: definitionsDate)) {
            return .failed(message: "Scanning engine is not ready: \(reason)")
        }
        guard let clamscan = locator.path(for: "clamscan") else {
            return .failed(message: "Scanning engine is not ready: ClamAV is not installed")
        }
        let roots = ScanScopes.roots(for: scope, home: home, exists: { FileManager.default.fileExists(atPath: $0) })
        guard !roots.isEmpty else {
            return .failed(message: "There is nothing to scan: none of the folders for this scan exist")
        }
        let startedAt = now()
        continuation.yield(.started(scope: scope))
        let arguments = ["--database=\(paths.databaseDirectory.path)", "-v", "--no-summary", "--recursive", "--"]
            + roots
        let context = Context(scope: scope, startedAt: startedAt, definitionsDate: definitionsDate)
        guard let process = launch(clamscan, arguments) else {
            let quitting = state.withLock { $0.quitRequested }
            return quitting
                ? .failed(message: "The scan was stopped because the app is quitting")
                : .finished(summary(ScanTally(), context, cancelled: true))
        }
        return await consume(process, continuation, context)
    }

    private struct Context {
        let scope: ScanScope
        let startedAt: Date
        let definitionsDate: Date?
    }

    /// Starts the child inside the same critical section that checks the quit and cancel flags and records the
    /// process, so `terminateNow()` / `cancelScan()` can never slip between the check and the start.
    private func launch(_ clamscan: String, _ arguments: [String]) -> RunningProcess? {
        state.withLock { current -> RunningProcess? in
            guard !current.quitRequested, !current.cancelRequested, !Task.isCancelled else { return nil }
            let process = runner.run(clamscan, arguments: arguments, environment: nil, lowPriority: true)
            current.current = process
            return process
        }
    }

    private func consume(
        _ process: RunningProcess,
        _ continuation: AsyncStream<ScanEvent>.Continuation,
        _ context: Context
    ) async -> ScanEvent {
        var tally = ScanTally()
        var tail = StderrTail()
        for await output in process.lines {
            let (text, isStderr) = switch output {
            case let .stdout(text): (text, false)
            case let .stderr(text): (text, true)
            }
            // Both streams are parsed: upstream prints `WARNING: Can't open file` on stderr, verdicts on stdout.
            let parsed = ClamScanOutputParser.parse(text)
            if isStderr, text.hasPrefix("ERROR:") {
                tally.noteFatal()
            }
            if let hit = tally.consume(parsed) {
                continuation.yield(.found(ScanFinding(
                    id: UUID(), path: hit.path, signature: hit.signature, foundAt: now()
                )))
            }
            if let progress = tally.throttledProgress(now: now(), interval: Self.progressInterval) {
                continuation.yield(progress)
            }
            // Only stderr feeds the failure message: a stdout line can carry any file name
            // (`error_log.txt: Empty file`).
            if isStderr, parsed == .ignored {
                tail.add(text, isStderr: true)
            }
        }
        if Task.isCancelled {
            // The consumer dropped the stream: nobody is listening, just make sure no child is left.
            await process.terminate(killGroup: true)
            return .failed(message: "The scan was abandoned")
        }
        let status = await process.wait()
        if status == 2 {
            tally.noteExitTwo()
        }
        if let closing = tally.finalProgress(now: now()) {
            continuation.yield(closing)
        }
        let cancelled = state.withLock { $0.cancelRequested }
        return Self.outcome(status: status, cancelled: cancelled, tally: tally, tail: tail) {
            summary(tally, context, cancelled: cancelled)
        }
    }

    /// Pure exit-code mapping, see the type documentation.
    static func outcome(
        status: Int32,
        cancelled: Bool,
        tally: ScanTally,
        tail: StderrTail,
        summary: () -> ScanSummary
    ) -> ScanEvent {
        if cancelled || status == 0 || status == 1 {
            return .finished(summary())
        }
        if status == 2, tally.scanned > 0, !tally.fatalSeen {
            return .finished(summary())
        }
        var prefix = "The scan failed (exit \(status))"
        if tally.findings > 0 {
            prefix += " after reporting \(tally.findings) finding\(tally.findings == 1 ? "" : "s")"
        }
        return .failed(message: tail.failureMessage(prefix: prefix))
    }

    private func summary(_ tally: ScanTally, _ context: Context, cancelled: Bool) -> ScanSummary {
        ScanSummary(
            scope: context.scope, scanned: tally.scanned, unreadable: tally.unreadable,
            findings: tally.findings, startedAt: context.startedAt, endedAt: now(), cancelled: cancelled,
            definitionsDate: context.definitionsDate, permissionDenied: tally.permissionDenied
        )
    }

    /// Why a scan cannot start, nil when it can. `updateNeeded(nil)` means there is no definitions database at all.
    static func refusal(_ status: EngineStatus) -> String? {
        switch status {
        case .ready, .updateNeeded(definitionsAge: .some): nil
        case .updateNeeded(definitionsAge: .none): "there are no virus definitions yet"
        case .homebrewMissing: "ClamAV is not installed and Homebrew was not found"
        case .notInstalled: "ClamAV is not installed"
        case .installing: "ClamAV is still being installed"
        case .downloadingDefinitions: "virus definitions are still downloading"
        case let .failed(message): message
        }
    }
}
