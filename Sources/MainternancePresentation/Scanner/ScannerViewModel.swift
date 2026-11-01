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
    /// True while a finding is being re-checked and moved.
    public internal(set) var isQuarantining = false

    @ObservationIgnored let scanner: any ScannerEngine
    @ObservationIgnored let quarantine: any QuarantineStoring
    @ObservationIgnored let statusStore: any ScanStatusRecording
    @ObservationIgnored private let openURL: @MainActor (URL) -> Void
    @ObservationIgnored private let protectedFolders: [URL]
    @ObservationIgnored private var restoredLastScan = false
    /// Findings of the current session's scan that were quarantined, by record id, so a restore can put them back.
    @ObservationIgnored var quarantinedFindings: [UUID: ScanFinding] = [:]
    @ObservationIgnored private var baseline: [ScanFinding] = []

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
        isQuarantining || run.isWorking
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
        guard let recorded = await statusStore.load(), !run.isWorking, findings.isEmpty, run == .idle else { return }
        findings = recorded.findings
        if let summary = recorded.summary {
            run = .finished(summary)
        }
    }

    public func install() async {
        guard canInstall else { return }
        await consume(scanner.install(), stage: "Starting the install…")
    }

    public func updateDefinitions() async {
        guard canUpdateDefinitions else { return }
        await consume(scanner.updateDefinitions(), stage: "Downloading definitions…")
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
        baseline = findings
        run = .scanning(scanned: 0, current: "")
        var summary: ScanSummary?
        var failure: String?
        var began = false
        for await event in scanner.scan(scope) {
            switch event {
            case .started:
                began = true
                findings = []
                quarantinedFindings = [:]
            case let .progress(scanned, current):
                run = .scanning(scanned: max(0, scanned), current: current)
            case let .found(finding):
                findings.append(finding)
            case let .finished(result):
                summary = result
            case let .failed(message):
                failure = message
            }
        }
        await finishScan(summary: summary, failure: failure, began: began)
    }

    private func finishScan(summary: ScanSummary?, failure: String?, began: Bool) async {
        if let summary {
            if summary.cancelled || failure != nil {
                keepUnresolvedBaseline()
            }
            run = .finished(summary)
            errorMessage = failure
            await statusStore.recordScan(summary, findings: findings)
            return
        }
        run = .idle
        errorMessage = failure ?? ScannerText.scanEndedWithoutResult
        guard began else { return }
        // A failed scan never clears older findings it did not re-check, and never hides the ones it reported.
        keepUnresolvedBaseline()
        await statusStore.updateFindings(findings)
    }

    /// Findings of the previous scan that this (cancelled or failed) scan did not re-report stay unresolved: only a
    /// completed scan can drop them.
    private func keepUnresolvedBaseline() {
        let known = Set(findings.map { Self.key($0) })
        findings += baseline.filter { !known.contains(Self.key($0)) }
    }

    private static func key(_ finding: ScanFinding) -> String {
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
