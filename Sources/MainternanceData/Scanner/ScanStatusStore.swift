import Foundation
import MainternanceDomain
import Synchronization

/// Persists what the scanner remembers as JSON in one file (mode `0o600`), so Home can show the scanner's state
/// without the Scanner screen being open and the next launch can list the findings again.
///
/// Format (version 1, shapes in `ScanStatusStore+Format.swift`): dates are seconds since 1970; a scope is `quick`,
/// `full` or `custom` (with `customPath`).
/// - `findings`: the unresolved findings. They are what matters for safety, so one damaged entry makes the whole
///   file unreadable rather than half-trusted.
/// - `lastScan`: the last COMPLETED scan, absent when none ever completed. A cancelled scan never replaces it. A
///   damaged `lastScan` only loses the summary (`summaryUnreadable`); the findings stay.
/// - `scanDidNotFinish`: a scan started and has not recorded its end (quit or crash), until one does.
/// - `unattributedFromIncompleteScan` and `unattributedScope`: detections of a cancelled or failed scan that could
///   not be attributed to a file, and the scope of that scan.
/// - `resolvedByQuarantine`: quarantine record id to the finding it resolved, so Restore can put it back. A damaged
///   entry is skipped, the rest stays.
/// - `earlierResultsUnreadable`: a file that could not be read was moved aside, so until a scan completes nothing
///   may be claimed about what it held.
///
/// A file that exists but cannot be read is never overwritten: the next save moves it aside as
/// `<name>.corrupt-<uuid>.json` first (like the quarantine store does with its manifest).
///
/// Writing: the logical state lives in memory (the file is decoded once, on first use). Every write to disk happens
/// inside one lock, so writes are serialised and the file always holds the latest logical state; that ordering is
/// guaranteed only for the writes to disk, not for snapshots that callers hand in concurrently. `remember` and
/// `recordScan` write at once. `rememberProgress` (one call per detection) writes the first call at once and then at
/// most once a second: a pending state is written by a one-second timer, by the next immediate write, by `flush()`
/// and by `flushNow()`, which the app's quit hook calls synchronously so no detection waits in memory at exit. After
/// `flushNow()` every later update writes at once (a timer may never fire during quit). A write that fails stays
/// pending, so the timer, the next write or a flush retries it.
public final class ScanStatusStore: ScanStatusRecording, Sendable {
    private static let currentVersion = 1
    private static let writeInterval: TimeInterval = 1

    private struct Logical {
        var summary: ScanSummary?
        var summaryUnreadable = false
        var earlierUnreadable = false
        var memory: ScanMemory
    }

    private struct State {
        var loaded = false
        var logical: Logical?
        var unreadableOnDisk = false
        var dirty = false
        var timerArmed = false
        /// Set by `flushNow()` (quit): from then on every update writes at once, a timer may never fire.
        var writeImmediately = false
        var lastWrite: Date?
        var writes = 0
        var reads = 0
    }

    private let file: URL
    private let now: @Sendable () -> Date
    private let sleep: @Sendable (Duration) async throws -> Void
    private let state = Mutex(State())
    private let writeHook = Mutex<(@Sendable (Int) -> Void)?>(nil)
    private let moveAsideFails = Mutex(false)

    /// Test seam: makes moving an unreadable file aside fail.
    var failMovingAside: Bool {
        get { moveAsideFails.withLock { $0 } }
        set { moveAsideFails.withLock { $0 = newValue } }
    }

    /// Test seam: called with the number of writes so far, after each write.
    var onWrite: (@Sendable (Int) -> Void)? {
        get { writeHook.withLock { $0 } }
        set { writeHook.withLock { $0 = newValue } }
    }

    public init(
        file: URL, now: @escaping @Sendable () -> Date = { Date() },
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.file = file
        self.now = now
        self.sleep = sleep
    }

    /// The default location: `<Application Support>/Mainternance/scan-status.json`.
    public static func defaultFile(paths: ClamAVPaths = ClamAVPaths()) -> URL {
        paths.supportDirectory.appendingPathComponent("scan-status.json", isDirectory: false)
    }

    var writeCount: Int {
        state.withLock { $0.writes }
    }

    var readCount: Int {
        state.withLock { $0.reads }
    }

    // MARK: Reading

    public func load() async -> RecordedScanStatus? {
        state.withLock { current in
            ensureLoaded(&current)
            return recorded(current.logical)
        }
    }

    public func loadState() async -> ScanStatusLoad {
        state.withLock { current in
            ensureLoaded(&current)
            if let logical = recorded(current.logical) {
                return .saved(logical)
            }
            return current.unreadableOnDisk ? .unreadable : .nothingSaved
        }
    }

    private func recorded(_ logical: Logical?) -> RecordedScanStatus? {
        guard let logical else { return nil }
        let memory = logical.memory
        return RecordedScanStatus(
            summary: logical.summary, summaryUnreadable: logical.summaryUnreadable, findings: memory.findings,
            unattributedFromIncompleteScan: memory.unattributedFromIncompleteScan,
            unattributedScope: memory.unattributedScope, scanDidNotFinish: memory.scanDidNotFinish,
            earlierResultsUnreadable: logical.earlierUnreadable, resolvedByQuarantine: memory.resolvedByQuarantine
        )
    }

    /// Reads the file the first time it is needed; afterwards the memory is the truth.
    private func ensureLoaded(_ current: inout State) {
        guard !current.loaded else { return }
        current.loaded = true
        current.reads += 1
        switch readFile() {
        case .missing:
            break
        case .unreadable:
            current.unreadableOnDisk = true
        case let .read(status):
            current.logical = Logical(
                summary: status.summary, summaryUnreadable: status.summaryUnreadable,
                earlierUnreadable: status.earlierResultsUnreadable,
                memory: ScanMemory(
                    findings: status.findings, unattributedFromIncompleteScan: status.unattributedFromIncompleteScan,
                    unattributedScope: status.unattributedScope, scanDidNotFinish: status.scanDidNotFinish,
                    resolvedByQuarantine: status.resolvedByQuarantine
                )
            )
        }
    }

    // MARK: Writing

    public func recordScan(_ summary: ScanSummary, memory: ScanMemory) async {
        let timer = state.withLock { current -> Bool in
            ensureLoaded(&current)
            let previous = current.logical
            let earlier = previous?.earlierUnreadable == true || current.unreadableOnDisk
            current.logical = Logical(
                summary: summary.cancelled ? previous?.summary : summary,
                summaryUnreadable: summary.cancelled && previous?.summaryUnreadable == true,
                // Only a completed scan clears the notice about an unreadable earlier file.
                earlierUnreadable: summary.cancelled && earlier,
                memory: memory
            )
            writeNow(&current)
            return needsTimer(&current)
        }
        if timer {
            armTimer()
        }
    }

    public func remember(_ memory: ScanMemory) async {
        let timer = state.withLock { current -> Bool in
            apply(memory, &current)
            writeNow(&current)
            return needsTimer(&current)
        }
        if timer {
            armTimer()
        }
    }

    public func rememberProgress(_ memory: ScanMemory) async {
        let timer = state.withLock { current -> Bool in
            apply(memory, &current)
            let recent = current.lastWrite.map { now().timeIntervalSince($0) < Self.writeInterval } ?? false
            if recent, !current.writeImmediately {
                current.dirty = true
            } else {
                writeNow(&current)
            }
            return needsTimer(&current)
        }
        if timer {
            armTimer()
        }
    }

    public func flush() async {
        flushNow()
    }

    /// Synchronous: writes what is still waiting. The app's quit hook calls it before the process exits.
    public func flushNow() {
        state.withLock { current in
            current.writeImmediately = true
            if current.dirty {
                writeNow(&current)
            }
        }
    }

    private func apply(_ memory: ScanMemory, _ current: inout State) {
        ensureLoaded(&current)
        let previous = current.logical
        current.logical = Logical(
            summary: previous?.summary, summaryUnreadable: previous?.summaryUnreadable == true,
            earlierUnreadable: previous?.earlierUnreadable == true || current.unreadableOnDisk, memory: memory
        )
    }

    /// Something is still pending (coalesced, or a write that failed) and no timer will write it: arm one. Not
    /// after the quit flush, when updates write at once and a timer may never fire.
    private func needsTimer(_ current: inout State) -> Bool {
        guard current.dirty, !current.timerArmed, !current.writeImmediately else { return false }
        current.timerArmed = true
        return true
    }

    private func armTimer() {
        Task { [self] in
            try? await sleep(.seconds(Self.writeInterval))
            state.withLock { current in
                current.timerArmed = false
                if current.dirty {
                    writeNow(&current)
                }
            }
        }
    }

    /// Writes the logical state (inside the lock, so writes are serialised); clears what was pending only when the
    /// write succeeded, so a failed write stays pending for the timer, the next write or a flush.
    private func writeNow(_ current: inout State) {
        guard let logical = current.logical else { return }
        current.dirty = true
        let memory = logical.memory
        let status = StatusFile(
            version: Self.currentVersion,
            findings: memory.findings.map(StoredFinding.init),
            lastScan: logical.summary.map { Lenient(StoredSummary($0)) },
            summaryUnreadable: logical.summaryUnreadable && logical.summary == nil ? true : nil,
            earlierResultsUnreadable: logical.earlierUnreadable ? true : nil,
            scanDidNotFinish: memory.scanDidNotFinish ? true : nil,
            unattributedFromIncompleteScan: max(0, memory.unattributedFromIncompleteScan),
            unattributedScope: memory.unattributedFromIncompleteScan > 0
                ? memory.unattributedScope.map(StoredScope.init) : nil,
            resolvedByQuarantine: memory.resolvedByQuarantine.map {
                Lenient(StoredLink(recordID: $0.key.uuidString, finding: StoredFinding($0.value)))
            }.sorted { ($0.value?.recordID ?? "") < ($1.value?.recordID ?? "") }
        )
        guard let data = try? JSONEncoder().encode(status) else { return }
        let manager = FileManager.default
        try? manager.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        if current.unreadableOnDisk {
            // Never write over a file that could not be moved aside: stay pending and try again later.
            guard keepUnreadableFileAside(manager) else { return }
            current.unreadableOnDisk = false
        }
        guard (try? data.write(to: file, options: .atomic)) != nil else { return }
        try? manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        current.dirty = false
        current.lastWrite = now()
        current.writes += 1
        writeHook.withLock { $0 }?(current.writes)
    }

    // MARK: File

    private enum FileContent {
        case missing
        case unreadable
        case read(RecordedScanStatus)
    }

    private func readFile() -> FileContent {
        guard FileManager.default.fileExists(atPath: file.path) else { return .missing }
        guard let data = try? Data(contentsOf: file),
              let stored = try? JSONDecoder().decode(StatusFile.self, from: data),
              stored.version == Self.currentVersion
        else {
            return .unreadable
        }
        var findings: [ScanFinding] = []
        for item in stored.findings {
            guard let finding = item.finding else { return .unreadable }
            findings.append(finding)
        }
        var links: [UUID: ScanFinding] = [:]
        for entry in (stored.resolvedByQuarantine ?? []).compactMap(\.value) {
            if let id = UUID(uuidString: entry.recordID), let finding = entry.finding.finding {
                links[id] = finding
            }
        }
        let summary = stored.lastScan?.value?.summary
        return .read(RecordedScanStatus(
            summary: summary,
            summaryUnreadable: stored.summaryUnreadable == true || (stored.lastScan != nil && summary == nil),
            findings: findings,
            unattributedFromIncompleteScan: stored.unattributedFromIncompleteScan ?? 0,
            unattributedScope: stored.unattributedScope?.scope,
            scanDidNotFinish: stored.scanDidNotFinish == true,
            earlierResultsUnreadable: stored.earlierResultsUnreadable == true,
            resolvedByQuarantine: links
        ))
    }
}

extension ScanStatusStore {
    /// A file that is there but cannot be read as a status is moved next to itself, never overwritten.
    /// True when nothing unreadable is left at `file` (moved aside, or already gone).
    private func keepUnreadableFileAside(_ manager: FileManager) -> Bool {
        guard manager.fileExists(atPath: file.path) else { return true }
        guard !failMovingAside else { return false }
        let name = file.deletingPathExtension().lastPathComponent
        let aside = file.deletingLastPathComponent()
            .appendingPathComponent("\(name).corrupt-\(UUID().uuidString).json")
        return (try? manager.moveItem(at: file, to: aside)) != nil
    }
}
