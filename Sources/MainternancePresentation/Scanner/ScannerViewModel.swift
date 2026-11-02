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
    /// The scope of the scan that left the count above.
    public internal(set) var unattributedScope: ScanScope?
    /// A scan was started and never recorded its end (the app was quit or crashed during it).
    public internal(set) var scanDidNotFinish = false
    /// A saved status file exists but could not be read (or was moved aside for that reason): nothing may be claimed
    /// about what it held until a scan completes.
    public internal(set) var savedResultsUnreadable = false
    /// True while a quarantined file is being put back.
    public internal(set) var isRestoring = false
    /// True while a finding is being re-checked and moved.
    public internal(set) var isQuarantining = false

    @ObservationIgnored let scanner: any ScannerEngine
    @ObservationIgnored let quarantine: any QuarantineStoring
    @ObservationIgnored let statusStore: any ScanStatusRecording
    @ObservationIgnored let fileExists: @Sendable (String) -> Bool
    @ObservationIgnored private let openURL: @MainActor (URL) -> Void
    @ObservationIgnored let protectedFolders: [URL]
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
        fileExists: @escaping @Sendable (String) -> Bool = pathStillExists,
        openURL: @escaping @MainActor (URL) -> Void
    ) {
        scanner = engine
        self.quarantine = quarantine
        self.statusStore = statusStore
        self.protectedFolders = protectedFolders
        self.fileExists = fileExists
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

    /// Loads what was saved the first time the screen opens. The flag is set only after the load came back (an empty
    /// store is a valid answer), and saved findings are merged in whatever the screen is doing meanwhile, so
    /// nothing saved is skipped.
    private func restoreLastScanOnce() async {
        guard !restoredLastScan else { return }
        let loaded = await statusStore.loadState()
        restoredLastScan = true
        let recorded: RecordedScanStatus
        switch loaded {
        case .nothingSaved:
            return
        case .unreadable:
            savedResultsUnreadable = true
            return
        case let .saved(status):
            recorded = status
        }
        savedResultsUnreadable = savedResultsUnreadable || recorded.earlierResultsUnreadable
        for finding in recorded.findings where !findings.contains(where: { Self.key($0) == Self.key(finding) }) {
            findings.append(finding)
        }
        for (id, finding) in recorded.resolvedByQuarantine where resolvedByQuarantine[id] == nil {
            resolvedByQuarantine[id] = finding
        }
        if unattributedFromIncompleteScan == 0 {
            unattributedFromIncompleteScan = recorded.unattributedFromIncompleteScan
            unattributedScope = recorded.unattributedScope
        }
        scanDidNotFinish = scanDidNotFinish || recorded.scanDidNotFinish
        if run == .idle, let summary = recorded.summary {
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
}

extension ScannerViewModel.RunState {
    var isWorking: Bool {
        switch self {
        case .installing, .scanning: true
        case .idle, .finished: false
        }
    }
}
