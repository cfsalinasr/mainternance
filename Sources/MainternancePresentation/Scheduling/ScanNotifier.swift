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

    /// "Problem alerts": any scan with files to review. "Weekly digest": every scheduled scan, clean or not; when it
    /// is posted it carries the count, so the separate alert is left out (one event, one notification).
    static func notices(for completion: ScanCompletion, preferences: AppPreferences) -> [UserNotice] {
        if completion.scheduled, preferences.weeklyDigest {
            return [digest(completion)]
        }
        guard preferences.problemAlerts, toReview(completion.summary) > 0 else { return [] }
        return [alert(completion)]
    }

    /// Files found plus detections that could not be tied to a file name (real detections all the same).
    static func toReview(_ summary: ScanSummary) -> Int {
        let (total, overflow) = max(0, summary.findings).addingReportingOverflow(summary.unattributedDetections)
        return overflow ? Int.max : total
    }

    private static func alert(_ completion: ScanCompletion) -> UserNotice {
        let body = completion.ranToTheEnd ? reviewHint : "The scan did not finish. \(reviewHint)"
        let title = "Mainternance found \(files(toReview(completion.summary))) to review"
        return UserNotice(id: findingsID, title: title, body: body)
    }

    private static func digest(_ completion: ScanCompletion) -> UserNotice {
        let summary = completion.summary
        let count = toReview(summary)
        let title = switch (completion.ranToTheEnd, count) {
        case (true, 0): "Weekly scan finished: nothing found"
        case (true, _): "Weekly scan finished: \(files(count)) to review"
        case (false, 0): "Weekly scan did not finish"
        case (false, _): "Weekly scan did not finish: \(files(count)) to review"
        }
        var body = "Scanned \(files(max(0, summary.scanned)))"
        body += completion.ranToTheEnd ? "." : " before it stopped."
        if summary.unreadable > 0 {
            let verb = summary.unreadable == 1 ? "was" : "were"
            body += " Some folders could not be read: \(files(summary.unreadable)) \(verb) skipped."
        }
        if count > 0 {
            body += " \(reviewHint)"
        }
        return UserNotice(id: digestID, title: title, body: body)
    }

    private static func files(_ count: Int) -> String {
        count == 1 ? "1 file" : "\(count) files"
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
