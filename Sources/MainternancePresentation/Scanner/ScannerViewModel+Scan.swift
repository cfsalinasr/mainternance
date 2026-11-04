import Foundation
import MainternanceDomain

extension ScannerViewModel {
    // MARK: - Scanning

    /// Returns the summary this scan ended with, or nil when it did not start or ended without one.
    @discardableResult
    public func startScan(_ scope: ScanScope) async -> ScanSummary? {
        await runScan(scope).summary
    }

    /// How one call to `runScan` ended.
    struct ScanRun {
        var summary: ScanSummary?
        /// The engine reported `.started`: the scan really ran, however it ended.
        var began = false
    }

    /// `startScan`, also saying whether the scan began (the scheduler gives its slot back when it did not).
    func runScan(_ scope: ScanScope) async -> ScanRun {
        guard canStartScan else { return ScanRun() }
        if case let .custom(url) = scope, isProtected(url) {
            errorMessage = ScannerText.protectedFolder
            return ScanRun()
        }
        let scheduled = startingScheduledScan
        let staleDays = staleDefinitionsDays
        errorMessage = nil
        notice = nil
        pendingQuarantine = nil
        // What this scan will walk is fixed now; the end of the scan judges findings against exactly that.
        let coverage = scanner.coverage(of: scope)
        // The old list stays as it is while the scan runs: only a COMPLETED scan may drop a finding.
        run = .scanning(scanned: 0, current: "")
        var outcome = ScanOutcome()
        for await event in scanner.scan(scope) {
            switch event {
            case .started:
                outcome.began = true
                scanDidNotFinish = true // Until its end is recorded, a restart must not look like a finished scan.
                await statusStore.remember(memory)
            case let .progress(scanned, current):
                run = .scanning(scanned: max(0, scanned), current: current)
            case let .found(finding):
                merge(finding)
                outcome.refound.insert(Self.key(finding))
                // Handed over at once (a quit kills the scan); the store coalesces the actual writes and flushes on
                // quit.
                await statusStore.rememberProgress(memory)
            case let .finished(result):
                outcome.summary = result
            case let .failed(message):
                outcome.failure = message
            case let .unattributed(count):
                outcome.unattributed = max(outcome.unattributed, count)
            }
        }
        await finish(scope, coverage, outcome)
        report(outcome, scheduled: scheduled, staleDays: staleDays)
        return ScanRun(summary: outcome.summary, began: outcome.began)
    }

    /// One callback per scan that ran: `onScanCompleted` when it ended with a summary, `onScanFailed` when it began
    /// and failed without one, nothing when the engine refused it before it began.
    private func report(_ outcome: ScanOutcome, scheduled: Bool, staleDays: Int?) {
        if let summary = outcome.summary {
            onScanCompleted?(ScanCompletion(
                summary: summary, scheduled: scheduled, failed: outcome.failure != nil, staleDefinitionsDays: staleDays
            ))
        } else if outcome.began {
            // Counts only: the failure text can hold a path, and notifications never carry one.
            onScanFailed?(ScanFailure(
                found: outcome.refound.count, unattributedDetections: outcome.unattributed, scheduled: scheduled,
                staleDefinitionsDays: staleDays
            ))
        }
    }

    /// What one scan reported, collected while its events stream in.
    private struct ScanOutcome {
        var summary: ScanSummary?
        var failure: String?
        var began = false
        var unattributed = 0
        var refound: Set<String> = []
    }

    /// The weekly scheduler updated the definitions before its scan and the update failed: the scan cleared the
    /// message when it started, so the reason is put back next to whatever the scan itself reported.
    func noteScheduledUpdateFailure(_ failure: String) {
        let note = ScannerText.scheduledUpdateFailed(failure)
        errorMessage = [errorMessage, note].compactMap(\.self).joined(separator: " ")
    }

    /// A finding the scan reports replaces the older entry for the same file and detection, otherwise it is added.
    func merge(_ finding: ScanFinding) {
        if let index = findings.firstIndex(where: { $0.path == finding.path && $0.signature == finding.signature }) {
            findings[index] = finding
        } else {
            findings.append(finding)
        }
    }

    private func finish(_ scope: ScanScope, _ coverage: ScanCoverage, _ outcome: ScanOutcome) async {
        if let summary = outcome.summary {
            if summary.cancelled || outcome.failure != nil {
                noteIncompleteScan(scope, detections: max(summary.unattributedDetections, outcome.unattributed))
            } else {
                resolve(summary, coverage, refound: outcome.refound)
            }
            scanDidNotFinish = false
            if !summary.cancelled, outcome.failure == nil {
                savedResultsUnreadable = false // a completed scan wrote a fresh, readable status
            }
            run = .finished(summary)
            errorMessage = outcome.failure
            await statusStore.recordScan(summary, memory: memory)
            return
        }
        run = .idle
        errorMessage = outcome.failure ?? ScannerText.scanEndedWithoutResult
        guard outcome.began else { return }
        // A failed scan drops nothing, keeps every finding it reported and the detections it could not attribute.
        noteIncompleteScan(scope, detections: outcome.unattributed)
        scanDidNotFinish = false
        await statusStore.remember(memory)
    }

    /// Detections of a cancelled or failed scan that could not be attributed stay counted. Counts of one scope keep
    /// the larger; counts of different scopes add up under the broader scope (full), so a later quick scan cannot
    /// reset what a full scan left.
    private func noteIncompleteScan(_ scope: ScanScope, detections: Int) {
        guard detections > 0 else { return }
        guard unattributedFromIncompleteScan > 0 else {
            unattributedFromIncompleteScan = detections
            unattributedScope = scope
            return
        }
        if unattributedScope == scope {
            unattributedFromIncompleteScan = max(unattributedFromIncompleteScan, detections)
        } else {
            // Different scopes: no single narrower scope can vouch for the sum, so only a full scan resets it.
            unattributedFromIncompleteScan = min(unattributedFromIncompleteScan + detections, Int.max / 2)
            unattributedScope = .full
        }
    }

    /// A COMPLETED scan is the only thing that can resolve an older finding. It drops one only when it covered the
    /// path (roots, exclusions, real paths), did not detect it again, AND either read everything (nothing unreadable,
    /// no permission errors, nothing unattributed) or the file is gone. In a folder it could not read, an existing
    /// file stays unresolved.
    ///
    /// It also resets the unattributed count of unfinished scans when it is a full scan or one of the count's own
    /// scope, and had no unattributed detections itself. Unreadable folders do not block this, otherwise the count
    /// could never clear on a Mac without Full Disk Access (which always has some); the unfinished scan could read
    /// the file it detected, so the next covering scan normally reads and counts it again. Mixed scopes are stored
    /// as full, so only a full scan resets them.
    private func resolve(_ summary: ScanSummary, _ coverage: ScanCoverage, refound: Set<String>) {
        let readEverything = summary.unreadable == 0 && summary.permissionDenied == 0
            && summary.unreadableFolders == 0 && summary.tooLarge == 0 && summary.unattributedDetections == 0
        findings = findings.filter { finding in
            guard !refound.contains(Self.key(finding)), coverage.covers(finding.path) else { return true }
            return !readEverything && fileExists(finding.path)
        }
        let coversTheCount = summary.scope == .full || summary.scope == unattributedScope
        if summary.unattributedDetections == 0, unattributedFromIncompleteScan > 0, coversTheCount {
            unattributedFromIncompleteScan = 0
            unattributedScope = nil
        }
    }

    /// Everything the scanner remembers between launches.
    var memory: ScanMemory {
        ScanMemory(
            findings: findings, unattributedFromIncompleteScan: unattributedFromIncompleteScan,
            unattributedScope: unattributedScope, scanDidNotFinish: scanDidNotFinish,
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
