import Foundation
import MainternanceDomain
import Synchronization

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

    struct State {
        var busy = false
        var current: RunningProcess?
        var cancelRequested = false
        var quitRequested = false
    }

    let locator: ToolLocator
    private let runner: ProcessRunning
    let paths: ClamAVPaths
    private let definitions: DefinitionsStore
    private let installer: ClamAVInstaller
    private let now: @Sendable () -> Date
    let home: URL
    let fileExists: @Sendable (String) -> Bool
    let isRegularFile: @Sendable (String) -> Bool
    let state = Mutex(State())

    public init(
        locator: ToolLocator,
        runner: ProcessRunning,
        paths: ClamAVPaths,
        definitions: DefinitionsStore,
        installer: ClamAVInstaller,
        environment: Environment = Environment()
    ) {
        self.locator = locator
        self.runner = runner
        self.paths = paths
        self.definitions = definitions
        self.installer = installer
        now = environment.now
        home = environment.home
        fileExists = environment.fileExists
        isRegularFile = environment.isRegularFile
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

    func definitionsDateNow() -> Date? {
        definitions.definitionsDate()
    }

    func statusNow(definitionsDate: Date?) -> EngineStatus {
        status(definitionsDate: definitionsDate)
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

    /// Claims the single-flight slot shared by scans and verifications.
    func claimSlot() -> Bool {
        state.withLock { current -> Bool in
            guard !current.busy else { return false }
            current.busy = true
            current.cancelRequested = false
            return true
        }
    }

    func releaseSlot() {
        state.withLock {
            $0.busy = false
            $0.current = nil
        }
    }

    public func scan(_ scope: ScanScope) -> AsyncStream<ScanEvent> {
        let claimed = claimSlot()
        return AsyncStream { continuation in
            guard claimed else {
                continuation.yield(.failed(message: Self.busyMessage))
                continuation.finish()
                return
            }
            let task = Task { [self] in
                let last = await execute(scope, continuation)
                // Release before the terminal event, so a consumer that reacts to it can start the next scan.
                releaseSlot()
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
        let excluded = ScanExclusions.directories(for: scope, home: home, paths: paths)
        let arguments = Self.scanArguments(database: paths.databaseDirectory.path, excluded: excluded, roots: roots)
        let context = Context(
            scope: scope,
            startedAt: startedAt,
            definitionsDate: definitionsDate,
            roots: roots,
            excluded: excluded,
            ownDirectories: Set(excluded).subtracting(cloudDirectories())
        )
        guard let process = launch(clamscan, arguments) else {
            let quitting = state.withLock { $0.quitRequested }
            return quitting
                ? .failed(message: "The scan was stopped because the app is quitting")
                : .finished(summary(ScanTally(), context, cancelled: true))
        }
        return await consume(process, continuation, context)
    }

    struct Context {
        let scope: ScanScope
        let startedAt: Date
        let definitionsDate: Date?
        let roots: [String]
        let excluded: [String]
        /// Excluded folders that are the app's own (quarantine, ClamAV), computed once per scan.
        let ownDirectories: Set<String>
    }

    /// Starts the child inside the same critical section that checks the quit and cancel flags and records the
    /// process, so `terminateNow()` / `cancelScan()` can never slip between the check and the start. The child is
    /// started with downloads of online-only (iCloud) files turned off, see `DatalessPolicy`.
    /// `runner.run` therefore executes WITH the lock held: a concurrent `terminateNow()` (the quit hook) or
    /// `cancelScan()` may block for the duration of the spawn (milliseconds), and a runner must never call back
    /// into the scanner.
    func launch(_ clamscan: String, _ arguments: [String]) -> RunningProcess? {
        state.withLock { current -> RunningProcess? in
            guard !current.quitRequested, !current.cancelRequested, !Task.isCancelled else { return nil }
            let process = DatalessPolicy.withMaterializationOff {
                runner.run(clamscan, arguments: arguments, environment: nil, lowPriority: true)
            }
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
            let parsed = vetted(ClamScanOutputParser.parse(text), context: context, tally: &tally)
            // Only a stderr `ERROR:` line is fatal; a `WARNING:` or any stdout line never is.
            if isStderr, text.hasPrefix("ERROR:") {
                tally.noteFatal()
            }
            if let hit = tally.consume(parsed, fromStderr: isStderr) {
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
        tally.noteExit(status: status)
        if let closing = tally.finalProgress(now: now()) {
            continuation.yield(closing)
        }
        let cancelled = state.withLock { $0.cancelRequested }
        let result = Self.outcome(status: status, cancelled: cancelled, tally: tally, tail: tail) {
            summary(tally, context, cancelled: cancelled)
        }
        if case .failed = result, tally.unattributedDetections > 0 {
            // The count is delivered as a value, so no consumer has to read it out of the message text.
            continuation.yield(.unattributed(detections: tally.unattributedDetections))
        }
        return result
    }

    private func summary(_ tally: ScanTally, _ context: Context, cancelled: Bool) -> ScanSummary {
        ScanSummary(
            scope: context.scope, scanned: tally.scanned, unreadable: tally.unreadable,
            findings: tally.findings, startedAt: context.startedAt, endedAt: now(), cancelled: cancelled,
            definitionsDate: context.definitionsDate, permissionDenied: tally.permissionDenied,
            unattributedDetections: tally.unattributedDetections, tooLarge: tally.tooLarge,
            unreadableFolders: tally.unreadableFolders
        )
    }
}

public extension ClamAVScanner {
    /// What the scanner reads from its surroundings: the clock, the home folder and whether a path exists. The
    /// defaults are the real ones; tests replace them.
    struct Environment: Sendable {
        let now: @Sendable () -> Date
        let home: URL
        let fileExists: @Sendable (String) -> Bool
        let isRegularFile: @Sendable (String) -> Bool

        public init(
            now: @escaping @Sendable () -> Date = { Date() },
            home: URL = FileManager.default.homeDirectoryForCurrentUser,
            fileExists: @escaping @Sendable (String) -> Bool = ScanPathRules.lstatExists,
            isRegularFile: @escaping @Sendable (String) -> Bool = { ScanPathRules.isRegularFile($0) }
        ) {
            self.now = now
            self.home = home
            self.fileExists = fileExists
            self.isRegularFile = isRegularFile
        }
    }
}
