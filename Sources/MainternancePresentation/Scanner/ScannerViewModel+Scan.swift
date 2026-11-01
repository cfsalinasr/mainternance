import Foundation
import MainternanceDomain

extension ScannerViewModel {
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
                await statusStore.remember(memory) // Saved at once: a quit kills the scan and nothing after is run.
            case let .finished(result):
                outcome.summary = result
            case let .failed(message):
                outcome.failure = message
            case let .unattributed(count):
                outcome.unattributed = max(outcome.unattributed, count)
            }
        }
        await finish(scope, coverage, outcome)
    }

    /// What one scan reported, collected while its events stream in.
    private struct ScanOutcome {
        var summary: ScanSummary?
        var failure: String?
        var began = false
        var unattributed = 0
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

    private func finish(_ scope: ScanScope, _ coverage: ScanCoverage, _ outcome: ScanOutcome) async {
        if let summary = outcome.summary {
            if summary.cancelled || outcome.failure != nil {
                noteIncompleteScan(scope, detections: max(summary.unattributedDetections, outcome.unattributed))
            } else {
                resolve(summary, coverage, refound: outcome.refound)
            }
            scanDidNotFinish = false
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
            unattributedFromIncompleteScan = min(unattributedFromIncompleteScan + detections, Int.max / 2)
            unattributedScope = (unattributedScope == .full || scope == .full) ? .full : scope
        }
    }

    /// A COMPLETED scan is the only thing that can resolve an older finding. It drops one only when it covered the
    /// path (roots, exclusions, real paths), did not detect it again, AND either read everything (nothing unreadable,
    /// no permission errors, nothing unattributed) or the file is gone. In a folder it could not read, an existing
    /// file stays unresolved. It also resets the unattributed count of unfinished scans, but only one of its own
    /// scope or a full scan, and only when it had no unattributed detections itself.
    private func resolve(_ summary: ScanSummary, _ coverage: ScanCoverage, refound: Set<String>) {
        let readEverything = summary.unreadable == 0 && summary.permissionDenied == 0
            && summary.unattributedDetections == 0
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
