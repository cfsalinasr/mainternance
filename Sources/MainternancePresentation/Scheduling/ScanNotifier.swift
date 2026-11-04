import Foundation
import MainternanceDomain

/// How one scan ended, as the Scanner model reports it.
public struct ScanCompletion: Equatable, Sendable {
    public let summary: ScanSummary
    /// The weekly scheduler started this scan.
    public let scheduled: Bool
    /// The scan reported an error at its end; its summary covers only the part that ran.
    public let failed: Bool

    public init(summary: ScanSummary, scheduled: Bool, failed: Bool) {
        self.summary = summary
        self.scheduled = scheduled
        self.failed = failed
    }

    /// Not cancelled and no error: only then may "nothing found" be said.
    public var ranToTheEnd: Bool {
        !summary.cancelled && !failed
    }
}

/// The notification wording for a finished scan. Counts only, never a file name. Pure, so tests pin it.
enum ScanNotices {
    static let findingsID = "scan-findings"
    static let digestID = "weekly-digest"
    static let reviewHint = "Open Mainternance and go to Scanner to review them."

    /// "Problem alerts": any scan with something to review. "Weekly digest": every scheduled scan that finished with
    /// a result, clean or not; when it is posted it carries the count, so the separate alert is left out (one event,
    /// one notification).
    static func notices(for completion: ScanCompletion, preferences: AppPreferences) -> [UserNotice] {
        if completion.scheduled, preferences.weeklyDigest {
            return [digest(completion)]
        }
        guard preferences.problemAlerts, toReview(completion.summary) > 0 else { return [] }
        return [alert(completion)]
    }

    /// Files found plus detections that could not be tied to a file name (real detections all the same); zero means
    /// nothing to review.
    static func toReview(_ summary: ScanSummary) -> Int {
        let (total, overflow) = max(0, summary.findings).addingReportingOverflow(summary.unattributedDetections)
        return overflow ? Int.max : total
    }

    private static func alert(_ completion: ScanCompletion) -> UserNotice {
        let body = completion.ranToTheEnd ? reviewHint : "The scan did not finish. \(reviewHint)"
        let title = "Mainternance found \(toReviewText(completion.summary)) to review"
        return UserNotice(id: findingsID, title: title, body: body)
    }

    private static func digest(_ completion: ScanCompletion) -> UserNotice {
        let summary = completion.summary
        let count = toReview(summary)
        let found = toReviewText(summary)
        let title = switch (completion.ranToTheEnd, count) {
        case (true, 0): "Weekly scan finished: nothing found"
        case (true, _): "Weekly scan finished: \(found) to review"
        case (false, 0): "Weekly scan did not finish"
        case (false, _): "Weekly scan did not finish: \(found) to review"
        }
        var body = "Scanned \(files(max(0, summary.scanned)))"
        body += completion.ranToTheEnd ? "." : " before it stopped."
        // `unreadable` counts files; folders and files too large to scan are counted on their own.
        if summary.unreadable > 0 {
            body += " \(files(summary.unreadable)) could not be read."
        }
        if summary.unreadableFolders > 0 {
            body += " \(counted(summary.unreadableFolders, "folder")) could not be opened."
        }
        if summary.tooLarge > 0 {
            body += " \(files(summary.tooLarge)) \(summary.tooLarge == 1 ? "was" : "were") too large to scan."
        }
        if count > 0 {
            body += " \(reviewHint)"
        }
        return UserNotice(id: digestID, title: title, body: body)
    }

    /// "2 files", "1 detection" (found but not tied to a file, so not called a file), or "2 files and 1 detection".
    static func toReviewText(_ summary: ScanSummary) -> String {
        let fileCount = max(0, summary.findings)
        let detections = max(0, summary.unattributedDetections)
        switch (fileCount, detections) {
        case (_, 0): return files(fileCount)
        case (0, _): return counted(detections, "detection")
        default: return "\(files(fileCount)) and \(counted(detections, "detection"))"
        }
    }

    private static func files(_ count: Int) -> String {
        counted(count, "file")
    }

    private static func counted(_ count: Int, _ noun: String) -> String {
        count == 1 ? "1 \(noun)" : "\(count) \(noun)s"
    }
}

/// Turns finished scans into notifications, following the Settings toggles. Posts only when macOS allows it and
/// never asks for permission itself (Settings does, when a toggle is turned on).
@MainActor
public final class ScanNotifier {
    private let notifications: any NotificationPosting
    private var preferences: AppPreferences = .defaults

    public init(notifications: any NotificationPosting) {
        self.notifications = notifications
    }

    public func update(_ preferences: AppPreferences) {
        self.preferences = preferences
    }

    public func scanCompleted(_ completion: ScanCompletion) async {
        let notices = ScanNotices.notices(for: completion, preferences: preferences)
        guard !notices.isEmpty, await notifications.authorization() == .allowed else { return }
        for notice in notices {
            await notifications.post(notice)
        }
    }
}
