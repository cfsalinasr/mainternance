import Foundation
import MainternanceDomain

/// How one scan ended, as the Scanner model reports it.
public struct ScanCompletion: Equatable, Sendable {
    public let summary: ScanSummary
    /// The weekly scheduler started this scan.
    public let scheduled: Bool
    /// The scan reported an error at its end; its summary covers only the part that ran.
    public let failed: Bool
    /// How old (whole days) the virus definitions were when the scan started, when older than a week; else nil.
    public let staleDefinitionsDays: Int?

    public init(summary: ScanSummary, scheduled: Bool, failed: Bool, staleDefinitionsDays: Int? = nil) {
        self.summary = summary
        self.scheduled = scheduled
        self.failed = failed
        self.staleDefinitionsDays = staleDefinitionsDays
    }

    /// Not cancelled and no error: only then may "nothing found" be said.
    public var ranToTheEnd: Bool {
        !summary.cancelled && !failed
    }
}

/// A scan that started and then failed without a summary (clamscan crashed, a fatal error). Counts only: the
/// failure text can hold a path.
public struct ScanFailure: Equatable, Sendable {
    /// Files this scan reported before it failed (they are listed on the Scanner screen).
    public let found: Int
    /// Detections it reported that could not be tied to a file.
    public let unattributedDetections: Int
    public let scheduled: Bool
    /// How old (whole days) the virus definitions were when the scan started, when older than a week; else nil.
    public let staleDefinitionsDays: Int?

    public init(found: Int, unattributedDetections: Int, scheduled: Bool, staleDefinitionsDays: Int?) {
        self.found = found
        self.unattributedDetections = unattributedDetections
        self.scheduled = scheduled
        self.staleDefinitionsDays = staleDefinitionsDays
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

    /// A scheduled scan with the digest on says it could not finish, with what it found so far; otherwise only
    /// something to review is alerted, like a finished scan.
    static func notices(for failure: ScanFailure, preferences: AppPreferences) -> [UserNotice] {
        let count = toReview(files: failure.found, detections: failure.unattributedDetections)
        let found = toReviewText(fileCount: failure.found, detections: failure.unattributedDetections)
        if failure.scheduled, preferences.weeklyDigest {
            var body = staleText(failure.staleDefinitionsDays).map { "\($0). " } ?? ""
            body += count > 0 ? "It found \(found) before it stopped. \(reviewHint)" : whatHappenedHint
            return [UserNotice(id: digestID, title: "The weekly scan could not finish", body: body)]
        }
        guard preferences.problemAlerts, count > 0 else { return [] }
        return [UserNotice(
            id: findingsID, title: "Mainternance found \(found) to review",
            body: "The scan did not finish. \(reviewHint)"
        )]
    }

    static let whatHappenedHint = "Open Mainternance and go to Scanner to see what happened."

    /// "The virus definitions are 40 days old"; nil when they were fresh.
    static func staleText(_ days: Int?) -> String? {
        days.map { "The virus definitions are \(counted(max(0, $0), "day")) old" }
    }

    /// Files found plus detections that could not be tied to a file name (real detections all the same); zero means
    /// nothing to review.
    static func toReview(_ summary: ScanSummary) -> Int {
        toReview(files: summary.findings, detections: summary.unattributedDetections)
    }

    static func toReview(files: Int, detections: Int) -> Int {
        let (total, overflow) = max(0, files).addingReportingOverflow(max(0, detections))
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
        let stale = staleText(completion.staleDefinitionsDays)
        let title = switch (completion.ranToTheEnd, count) {
        // Old definitions can miss what newer ones catch: "nothing found" would claim more than the scan can.
        case (true, 0) where stale != nil: "Weekly scan finished with old virus definitions"
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
        if let stale {
            body += " \(stale), so newer threats may be missed."
        }
        if count > 0 {
            body += " \(reviewHint)"
        }
        return UserNotice(id: digestID, title: title, body: body)
    }

    /// "2 files", "1 detection" (found but not tied to a file, so not called a file), or "2 files and 1 detection".
    static func toReviewText(_ summary: ScanSummary) -> String {
        toReviewText(fileCount: summary.findings, detections: summary.unattributedDetections)
    }

    static func toReviewText(fileCount: Int, detections: Int) -> String {
        let fileCount = max(0, fileCount)
        let detections = max(0, detections)
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
        await post(ScanNotices.notices(for: completion, preferences: preferences))
    }

    public func scanFailed(_ failure: ScanFailure) async {
        await post(ScanNotices.notices(for: failure, preferences: preferences))
    }

    private func post(_ notices: [UserNotice]) async {
        guard !notices.isEmpty, await notifications.authorization() == .allowed else { return }
        for notice in notices {
            await notifications.post(notice)
        }
    }
}
