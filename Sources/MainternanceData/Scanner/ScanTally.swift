import Foundation
import MainternanceDomain

/// Running totals of one scan, fed one parsed line at a time. Pure, so the counting rules are easy to pin.
struct ScanTally {
    private(set) var scanned = 0
    private(set) var unreadable = 0
    private(set) var permissionDenied = 0
    private(set) var findings = 0
    private(set) var current = ""
    /// Lines dropped because their path was not plausible (forged by a file name, outside the roots). Debug only.
    private(set) var ignoredSuspicious = 0
    /// A stderr `ERROR:` line (clamscan's fatal messages, for example a database problem) was seen.
    private(set) var fatalSeen = false
    private var unreadablePaths = Set<String>()
    private var reportedScanned = 0
    private var lastProgressAt: Date?

    static let maxTrackedPaths = 10000

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
