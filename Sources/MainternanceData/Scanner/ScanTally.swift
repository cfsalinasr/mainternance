import Foundation
import MainternanceDomain

/// Running totals of one scan, fed one parsed line at a time. Pure, so the counting rules are easy to pin.
struct ScanTally {
    private(set) var scanned = 0
    private(set) var unreadable = 0
    private(set) var permissionDenied = 0
    private(set) var findings = 0
    /// Files skipped for clamscan's size and scan limits; never scanned, never findings.
    private(set) var tooLarge = 0
    /// Folders clamscan could not open; nothing inside them was scanned. Not part of `unreadable` (files).
    private(set) var unreadableFolders = 0
    /// clamscan's own `Infected files:` total (the last one read from stdout), nil when it printed none.
    private(set) var infectedTotal: Int?
    private(set) var current = ""
    /// Lines dropped because their path was not plausible (forged by a file name, outside the roots). Debug only.
    private(set) var ignoredSuspicious = 0
    /// A stderr `ERROR:` line (clamscan's fatal messages, for example a database problem) was seen.
    private(set) var fatalSeen = false
    /// Every path counted as not scanned (unreadable file, unreadable folder, too large), so each counts once.
    private var notScannedPaths = Set<String>()
    private var reportedScanned = 0
    private var lastProgressAt: Date?

    static let maxTrackedPaths = 10000

    /// A detection (FOUND) that was dropped because its path is not a plausible result of this scan.
    private(set) var unattributedDetections = 0

    mutating func noteDroppedDetection() {
        unattributedDetections = min(unattributedDetections + 1, Int.max / 2)
    }

    /// The last stdout total wins: clamscan prints its summary last, so a forged earlier line cannot lower it.
    mutating func noteInfectedTotal(_ total: Int) {
        infectedTotal = max(0, total)
    }

    /// clamscan exited 1 (infected files found). Checked against real ClamAV 1.5.4: a file over a size limit prints
    /// a `Heuristics.Limits.Exceeded` alert but is counted as an error, never as an infected file, and a scan with
    /// only such files exits 2 with `Infected files: 0`. So clamscan's own total is exactly the number of real
    /// detections: every infected file that is not an accepted finding is a detection that could not be attributed
    /// (a FOUND line lost to a file name, for example). A too-large alert must never offset it, or a forged alert
    /// could hide a detection. Without a total (crash, truncated output) exit 1 with no finding still fails closed.
    mutating func noteExitOne() {
        if let infectedTotal {
            let missing = infectedTotal - findings
            unattributedDetections = max(unattributedDetections, min(missing, Int.max / 2))
        }
        if findings == 0 {
            unattributedDetections = max(unattributedDetections, 1)
        }
    }

    mutating func noteExit(status: Int32) {
        switch status {
        case 0: unattributedDetections = 0 // exit 0 means no infection: a FOUND line seen was forged, not a detection
        case 1: noteExitOne()
        case 2: noteExitTwo()
        default: break
        }
    }

    mutating func noteSuspicious() {
        ignoredSuspicious = min(ignoredSuspicious + 1, Int.max / 2)
    }

    mutating func noteFatal() {
        fatalSeen = true
    }

    /// clamscan exited 2: per upstream, exit 2 without findings only comes from counted errors (`info.errors`) or
    /// a fatal start-up problem, so a scan that exits 2 never reports zero unreadable files. When no line named
    /// the failing file (for example an allocation failure), one unattributed error is recorded.
    mutating func noteExitTwo() {
        if unreadable == 0, unreadableFolders == 0 {
            unreadable = 1
        }
    }

    /// Counts the line and returns the finding, if the line was one. FOUND files count as scanned; unreadable
    /// files and folders and files too large to scan are never scanned and never clean.
    /// Only stdout carries clamscan's summary, so a total on stderr is never trusted.
    mutating func consume(_ line: ClamLine, fromStderr: Bool = false) -> (path: String, signature: String)? {
        switch line {
        case let .infectedTotal(total):
            if !fromStderr {
                noteInfectedTotal(total)
            }
        case let .scanned(path):
            scanned += 1
            current = path
        case let .found(path, signature):
            scanned += 1
            findings += 1
            current = path
            return (path, signature)
        case .unreadable, .unreadableFolder, .tooLarge:
            countNotScanned(line)
        case .ignored:
            break
        }
        return nil
    }

    /// Unreadable files, unreadable folders and files too large to scan, each path once.
    private mutating func countNotScanned(_ line: ClamLine) {
        switch line {
        case let .unreadable(path, isPermission):
            guard isFirstReport(of: path) else { return }
            unreadable += 1
            if isPermission {
                permissionDenied += 1
            }
        case let .unreadableFolder(path):
            guard isFirstReport(of: path) else { return }
            unreadableFolders += 1
        case let .tooLarge(path):
            guard isFirstReport(of: path) else { return }
            tooLarge += 1
            current = path
        default:
            return
        }
    }

    /// One entry per path, whatever number of messages clamscan printed for it. Past the cap the set stops growing
    /// (bounded memory) and every further line is counted.
    private mutating func isFirstReport(of path: String) -> Bool {
        if notScannedPaths.contains(path) {
            return false
        }
        if notScannedPaths.count < Self.maxTrackedPaths {
            notScannedPaths.insert(path)
        }
        return true
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
