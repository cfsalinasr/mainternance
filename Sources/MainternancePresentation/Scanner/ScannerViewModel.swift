import Foundation
import MainternanceDomain
import Observation

/// State and actions of the real Scanner screen. It talks to the engine, the quarantine store and the status store
/// only through their Domain ports, so tests run it with fakes and never touch a file or a process.
///
/// Rules it keeps: a quarantine always goes `requestQuarantine` -> `confirmQuarantine` (never automatic) and the
/// engine re-checks the file first; findings a scan reported stay listed even if the scan then fails or is
/// cancelled; a completed scan is the only thing that replaces the list; errors are plain readable text.
@MainActor
@Observable
public final class ScannerViewModel {
    public enum RunState: Equatable {
        case idle
        /// Installing the engine or downloading definitions; `progress` is nil when it cannot be measured.
        case installing(stage: String, progress: Double?)
        /// The engine does not report unreadable files while it runs, so the count is only known at the end.
        case scanning(scanned: Int, current: String)
        case finished(ScanSummary)
    }

    /// Nil until the first status check finished (the screen then says it is checking).
    public internal(set) var engine: EngineStatus?
    public internal(set) var run: RunState = .idle
    /// Unresolved findings: reported by a scan and not quarantined.
    public internal(set) var findings: [ScanFinding] = []
    /// Files really held in quarantine.
    public internal(set) var quarantined: [QuarantineRecord] = []
    /// Files that could not be moved and are still in their original place; never shown as contained.
    public internal(set) var notMoved: [QuarantineRecord] = []
    /// Files in the quarantine folder that no record describes (left untouched).
    public internal(set) var unclaimedCount = 0
    public internal(set) var pendingQuarantine: ScanFinding?
    public internal(set) var errorMessage: String?
    public internal(set) var notice: String?
    /// Detections of a cancelled or failed scan that could not be attributed to a file; counted as unresolved until
    /// a completed scan replaces the number.
    public internal(set) var unattributedFromIncompleteScan = 0
    /// True while a quarantined file is being put back.
    public internal(set) var isRestoring = false
    /// True while a finding is being re-checked and moved.
    public internal(set) var isQuarantining = false

    @ObservationIgnored let scanner: any ScannerEngine
    @ObservationIgnored let quarantine: any QuarantineStoring
    @ObservationIgnored let statusStore: any ScanStatusRecording
    @ObservationIgnored private let openURL: @MainActor (URL) -> Void
    @ObservationIgnored private let protectedFolders: [URL]
    @ObservationIgnored private var restoredLastScan = false
    /// Findings that were quarantined, by record id (remembered across launches), so a restore can put them back.
    @ObservationIgnored var resolvedByQuarantine: [UUID: ScanFinding] = [:]

    /// `openURL` opens a system URL (Full Disk Access settings); `protectedFolders` are folders a custom scan may
    /// not start in (the app's own quarantine and ClamAV folders).
    public init(
        engine: any ScannerEngine,
        quarantine: any QuarantineStoring,
        statusStore: any ScanStatusRecording,
        protectedFolders: [URL] = [],
        openURL: @escaping @MainActor (URL) -> Void
    ) {
        scanner = engine
        self.quarantine = quarantine
        self.statusStore = statusStore
        self.protectedFolders = protectedFolders
        self.openURL = openURL
    }

    // MARK: - Derived state

    /// True while the engine, a scan or a quarantine is working.
    public var isBusy: Bool {
        isQuarantining || isRestoring || run.isWorking
    }

    /// Scans start only when the engine is ready (or has old but present definitions) and nothing else runs.
    public var canStartScan: Bool {
        guard !isBusy, let engine else { return false }
        switch engine {
        case .ready, .updateNeeded(definitionsAge: .some): return true
        default: return false
        }
    }

    public var canInstall: Bool {
        !isBusy && engine == .notInstalled
    }

    public var canUpdateDefinitions: Bool {
        guard !isBusy, let engine else { return false }
        switch engine {
        case .ready, .updateNeeded: return true
        default: return false
        }
    }

    public var canCancel: Bool {
        if case .scanning = run {
            return true
        }
        return false
    }

    /// The last scan could not read files because macOS denied access.
    public var permissionDeniedCount: Int {
        if case let .finished(summary) = run {
            return summary.permissionDenied
        }
        return 0
    }

    public var needsFullDiskAccess: Bool {
        permissionDeniedCount > 0
    }

    public func openFullDiskAccessSettings() {
        if let url = URL(string: ScannerText.fullDiskAccessURL) {
            openURL(url)
        }
    }

    // MARK: - Engine status, install, definitions

    public func refreshStatus() async {
        await restoreLastScanOnce()
        let latest = await scanner.status()
        if !run.isWorking {
            engine = latest
        }
        await reloadQuarantine()
    }

    private func restoreLastScanOnce() async {
        guard !restoredLastScan else { return }
        restoredLastScan = true
        guard let recorded = await statusStore.load(), run == .idle else { return }
        findings = recorded.findings
        unattributedFromIncompleteScan = recorded.unattributedFromIncompleteScan
        resolvedByQuarantine = recorded.resolvedByQuarantine
        if let summary = recorded.summary {
            run = .finished(summary)
        }
    }

    public func install() async {
        guard canInstall else { return }
        await consume(scanner.install(), stage: ScannerText.installStarting)
    }

    public func updateDefinitions() async {
        guard canUpdateDefinitions else { return }
        await consume(scanner.updateDefinitions(), stage: ScannerText.updateStarting)
    }

    private func consume(_ stream: AsyncStream<InstallEvent>, stage: String) async {
        errorMessage = nil
        notice = nil
        run = .installing(stage: stage, progress: nil)
        var failure: String?
        for await event in stream {
            if case let .failed(message) = event {
                failure = message
            }
            apply(event)
        }
        run = .idle
        errorMessage = failure
        engine = await scanner.status()
    }

    func apply(_ event: InstallEvent) {
        guard case let .installing(stage, progress) = run else { return }
        switch event {
        case let .stage(text):
            run = .installing(stage: text, progress: nil)
        case let .progress(value):
            run = .installing(stage: stage, progress: value.map { $0.isFinite ? min(max($0, 0), 1) : 0 })
        case .finished, .failed:
            run = .installing(stage: stage, progress: progress)
        }
    }

    // MARK: - Scanning

    public func startScan(_ scope: ScanScope) async {
        guard canStartScan else { return }
        if case let .custom(url) = scope, isProtected(url) {
            errorMessage = ScannerText.protectedFolder
            return
        }
        errorMessage = nil
        notice = nil
        pendingQuarantine = nil
        // The old list stays as it is while the scan runs: only a COMPLETED scan may drop a finding.
        run = .scanning(scanned: 0, current: "")
        var outcome = ScanOutcome()
        for await event in scanner.scan(scope) {
            switch event {
            case .started:
                outcome.began = true
            case let .progress(scanned, current):
                run = .scanning(scanned: max(0, scanned), current: current)
            case let .found(finding):
                merge(finding)
                outcome.refound.insert(Self.key(finding))
            case let .finished(result):
                outcome.summary = result
            case let .failed(message):
                outcome.failure = message
            }
        }
        await finish(scope, outcome)
    }

    /// What one scan reported, collected while its events stream in.
    private struct ScanOutcome {
        var summary: ScanSummary?
        var failure: String?
        var began = false
        var refound: Set<String> = []
    }

    /// A finding the scan reports replaces the older entry for the same file and detection, otherwise it is added.
    func merge(_ finding: ScanFinding) {
        if let index = findings.firstIndex(where: { Self.key($0) == Self.key(finding) }) {
            findings[index] = finding
        } else {
            findings.append(finding)
        }
    }

    private func finish(_ scope: ScanScope, _ outcome: ScanOutcome) async {
        if let summary = outcome.summary {
            if summary.cancelled || outcome.failure != nil {
                unattributedFromIncompleteScan = max(unattributedFromIncompleteScan, summary.unattributedDetections)
            } else {
                dropWhatTheScanCovered(scope, refound: outcome.refound)
            }
            run = .finished(summary)
            errorMessage = outcome.failure
            await statusStore.recordScan(summary, memory: memory)
            return
        }
        run = .idle
        errorMessage = outcome.failure ?? ScannerText.scanEndedWithoutResult
        guard outcome.began else { return }
        // A failed scan drops nothing and keeps every finding it reported, and the detections it could not attribute.
        let count = ScanFailureNote.unattributedCount(in: outcome.failure ?? "")
        unattributedFromIncompleteScan = max(unattributedFromIncompleteScan, count)
        await statusStore.remember(memory)
    }

    /// A COMPLETED scan is the only thing that can resolve an older finding, and only one whose path it covered
    /// (under its roots and outside its exclusions) and did not detect again. Everything else stays unresolved.
    /// It also forgets quarantine links for covered paths (those files are no longer part of the last scan) and
    /// replaces the unattributed count of earlier unfinished scans.
    private func dropWhatTheScanCovered(_ scope: ScanScope, refound: Set<String>) {
        let coverage = scanner.coverage(of: scope)
        findings = findings.filter { refound.contains(Self.key($0)) || !coverage.covers($0.path) }
        resolvedByQuarantine = resolvedByQuarantine.filter { !coverage.covers($0.value.path) }
        unattributedFromIncompleteScan = 0
    }

    /// Everything the scanner remembers between launches.
    var memory: ScanMemory {
        ScanMemory(
            findings: findings, unattributedFromIncompleteScan: unattributedFromIncompleteScan,
            resolvedByQuarantine: resolvedByQuarantine
        )
    }

    static func key(_ finding: ScanFinding) -> String {
        finding.path + "\u{0}" + finding.signature
    }

    private func isProtected(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        return protectedFolders.contains { folder in
            let root = folder.standardizedFileURL.path
            return path == root || path.hasPrefix(root + "/") || root.hasPrefix(path + "/")
        }
    }

    public func cancel() async {
        guard canCancel else { return }
        await scanner.cancelScan()
    }
}

extension ScannerViewModel.RunState {
    var isWorking: Bool {
        switch self {
        case .installing, .scanning: true
        case .idle, .finished: false
        }
    }
}
