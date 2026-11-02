import Foundation
import MainternanceDomain
@testable import MainternancePresentation
import Testing

@MainActor
struct ScanNotifierTests {
    private func notifier(
        _ authorization: NotificationAuthorization = .allowed, alerts: Bool = true, digest: Bool = true
    ) -> (ScanNotifier, FakeNotifications) {
        let notifications = FakeNotifications(authorization)
        let notifier = ScanNotifier(notifications: notifications)
        var prefs = AppPreferences.defaults
        prefs.problemAlerts = alerts
        prefs.weeklyDigest = digest
        notifier.update(prefs)
        return (notifier, notifications)
    }

    private func completion(
        _ summary: ScanSummary, scheduled: Bool = false, failed: Bool = false
    ) -> ScanCompletion {
        ScanCompletion(summary: summary, scheduled: scheduled, failed: failed)
    }

    // MARK: Problem alerts

    @Test func findingsPostAnAlertWithCountsOnly() async {
        let (notifier, notifications) = notifier(digest: false)
        await notifier.scanCompleted(completion(makeSummary(findings: 3)))
        #expect(notifications.posted.count == 1)
        let notice = notifications.posted.first
        #expect(notice?.id == "scan-findings")
        #expect(notice?.title == "Mainternance found 3 files to review")
        #expect(notice?.body == "Open Mainternance and go to Scanner to review them.")
        await notifier.scanCompleted(completion(makeSummary(findings: 1)))
        #expect(notifications.posted.last?.title == "Mainternance found 1 file to review")
    }

    @Test func noticesNeverNameAFile() async {
        let (notifier, notifications) = notifier()
        await notifier.scanCompleted(completion(makeSummary(findings: 2, unattributed: 1)))
        await notifier.scanCompleted(completion(makeSummary(unreadable: 4, findings: 2), scheduled: true))
        #expect(!notifications.posted.isEmpty)
        for notice in notifications.posted {
            #expect(!notice.title.contains("/") && !notice.body.contains("/"))
            #expect(!notice.body.contains(".bin"))
        }
    }

    @Test func detectionsWithoutAFileNameCountAsFilesToReview() async {
        let (notifier, notifications) = notifier(digest: false)
        await notifier.scanCompleted(completion(makeSummary(findings: 0, unattributed: 2)))
        #expect(notifications.posted.map(\.title) == ["Mainternance found 2 files to review"])
    }

    @Test func aCleanScanPostsNoAlert() async {
        let (notifier, notifications) = notifier()
        await notifier.scanCompleted(completion(makeSummary(findings: 0)))
        #expect(notifications.posted.isEmpty)
    }

    @Test func alertsOffPostNothingForAManualScan() async {
        let (notifier, notifications) = notifier(alerts: false)
        await notifier.scanCompleted(completion(makeSummary(findings: 3)))
        #expect(notifications.posted.isEmpty)
    }

    @Test func findingsOfAnUnfinishedScanSaySoAndAreStillAlerted() async {
        let (notifier, notifications) = notifier(digest: false)
        await notifier.scanCompleted(completion(makeSummary(findings: 2, cancelled: true)))
        #expect(notifications.posted.first?.title == "Mainternance found 2 files to review")
        #expect(notifications.posted.first?.body
            == "The scan did not finish. Open Mainternance and go to Scanner to review them.")
    }

    // MARK: Weekly digest

    @Test func aCleanScheduledScanSaysNothingFoundWithCounts() async {
        let (notifier, notifications) = notifier()
        await notifier.scanCompleted(completion(makeSummary(scanned: 1234), scheduled: true))
        #expect(notifications.posted == [UserNotice(
            id: "weekly-digest", title: "Weekly scan finished: nothing found", body: "Scanned 1234 files."
        )])
    }

    @Test func unreadableFoldersAreMentioned() async {
        let (notifier, notifications) = notifier()
        await notifier.scanCompleted(completion(makeSummary(scanned: 50, unreadable: 1), scheduled: true))
        #expect(notifications.posted.first?.title == "Weekly scan finished: nothing found")
        #expect(notifications.posted.first?.body
            == "Scanned 50 files. Some folders could not be read: 1 file was skipped.")
        await notifier.scanCompleted(completion(makeSummary(scanned: 1, unreadable: 7), scheduled: true))
        #expect(notifications.posted.last?.body
            == "Scanned 1 file. Some folders could not be read: 7 files were skipped.")
    }

    /// One notification for one scheduled scan: the digest already carries the count, so no separate alert.
    @Test func aScheduledScanWithFindingsPostsOneDigest() async {
        let (notifier, notifications) = notifier()
        await notifier.scanCompleted(completion(makeSummary(scanned: 90, findings: 4), scheduled: true))
        #expect(notifications.posted == [UserNotice(
            id: "weekly-digest", title: "Weekly scan finished: 4 files to review",
            body: "Scanned 90 files. Open Mainternance and go to Scanner to review them."
        )])
    }

    @Test func withTheDigestOffAScheduledScanWithFindingsStillAlerts() async {
        let (notifier, notifications) = notifier(digest: false)
        await notifier.scanCompleted(completion(makeSummary(findings: 1), scheduled: true))
        #expect(notifications.posted.map(\.id) == ["scan-findings"])
        let (quiet, quietPosts) = self.notifier(digest: false)
        await quiet.scanCompleted(completion(makeSummary(), scheduled: true))
        #expect(quietPosts.posted.isEmpty)
    }

    @Test func aManualScanPostsNoDigest() async {
        let (notifier, notifications) = notifier()
        await notifier.scanCompleted(completion(makeSummary(scanned: 10)))
        #expect(notifications.posted.isEmpty)
    }

    @Test func anUnfinishedScheduledScanNeverSaysNothingFound() async {
        let (notifier, notifications) = notifier()
        await notifier.scanCompleted(completion(makeSummary(scanned: 10, cancelled: true), scheduled: true))
        await notifier.scanCompleted(completion(makeSummary(scanned: 20), scheduled: true, failed: true))
        await notifier.scanCompleted(completion(makeSummary(scanned: 30, findings: 2), scheduled: true, failed: true))
        let titles = notifications.posted.map(\.title)
        #expect(titles == [
            "Weekly scan did not finish", "Weekly scan did not finish",
            "Weekly scan did not finish: 2 files to review"
        ])
        #expect(notifications.posted.allSatisfy { !$0.title.contains("nothing") && !$0.body.contains("nothing") })
        #expect(notifications.posted.first?.body == "Scanned 10 files before it stopped.")
    }

    // MARK: Permission

    @Test(arguments: [NotificationAuthorization.denied, .unavailable, .notDetermined])
    func withoutPermissionNothingIsPosted(_ authorization: NotificationAuthorization) async {
        let (notifier, notifications) = notifier(authorization)
        await notifier.scanCompleted(completion(makeSummary(findings: 2), scheduled: true))
        await notifier.scanCompleted(completion(makeSummary(findings: 2)))
        #expect(notifications.posted.isEmpty)
        #expect(notifications.requests == 0) // never prompts from a background event
    }

    @Test func preferencesChangesApply() async {
        let (notifier, notifications) = notifier(alerts: false, digest: false)
        notifier.update(.defaults)
        await notifier.scanCompleted(completion(makeSummary(findings: 1)))
        #expect(notifications.posted.count == 1)
    }
}

/// The Scanner model tells finished scans apart: started by the weekly scheduler or by hand.
@MainActor
struct ScanCompletedHookTests {
    @Test func aManualScanReportsManual() async {
        let rig = await ScannerRig.ready()
        let seen = Recorded<ScanCompletion>()
        rig.model.onScanCompleted = { seen.add($0) }
        await rig.scanFinding([makeFinding(1)])
        #expect(seen.all == [ScanCompletion(
            summary: makeSummary(findings: 1), scheduled: false, failed: false
        )])
    }

    @Test func theSchedulersRunReportsScheduledAndLaterManualScansDoNot() async {
        let rig = await SchedulerRig.make(lastRun: nil, now: utc("2026-11-04 10:00"))
        let seen = Recorded<ScanCompletion>()
        rig.scanner.model.onScanCompleted = { seen.add($0) }
        await rig.scheduler.tick()
        await rig.scanner.model.startScan(.full)
        #expect(seen.all.map(\.scheduled) == [true, false])
        #expect(seen.all.first?.summary == makeSummary(scope: .quick, scanned: 12))
        #expect(!rig.scanner.model.startingScheduledScan)
    }

    @Test func aManualScanTriedDuringTheScheduledOneIsRejectedAndNotReported() async {
        let rig = await SchedulerRig.make(lastRun: nil, now: utc("2026-11-04 10:00"))
        let seen = Recorded<ScanCompletion>()
        rig.scanner.model.onScanCompleted = { seen.add($0) }
        rig.scanner.engine.configure { $0.holdScan = true; $0.scanEvents = [.started(scope: .quick)] }
        let scheduled = Task { await rig.scheduler.tick() }
        var calls = rig.scanner.engine.scanCalls.makeAsyncIterator()
        _ = await calls.next()
        await rig.scanner.model.startScan(.full) // rejected: a scan is running
        rig.scanner.engine.emit(.finished(makeSummary(scope: .quick)))
        rig.scanner.engine.finishScan()
        await scheduled.value
        #expect(seen.all.map(\.scheduled) == [true])
        #expect(rig.scanner.engine.scans == [.quick])
        #expect(!rig.scanner.model.startingScheduledScan)
    }

    @Test func aFailureAfterASummaryIsReportedAsFailed() async {
        let rig = await ScannerRig.ready()
        let seen = Recorded<ScanCompletion>()
        rig.model.onScanCompleted = { seen.add($0) }
        rig.engine.configure {
            $0.scanEvents = [.started(scope: .quick), .finished(makeSummary()), .failed(message: "engine stopped")]
        }
        await rig.model.startScan(.quick)
        #expect(seen.all.map(\.failed) == [true])
        #expect(seen.all.first?.ranToTheEnd == false)
    }

    @Test func aScanThatEndsWithoutASummaryReportsNothing() async {
        let rig = await ScannerRig.ready()
        let seen = Recorded<ScanCompletion>()
        rig.model.onScanCompleted = { seen.add($0) }
        rig.engine.configure { $0.scanEvents = [.started(scope: .quick), .failed(message: "no engine")] }
        await rig.model.startScan(.quick)
        #expect(seen.all.isEmpty)
    }

    @Test func completionRanToTheEndOnlyWhenNotCancelledAndNotFailed() {
        #expect(ScanCompletion(summary: makeSummary(), scheduled: false, failed: false).ranToTheEnd)
        #expect(!ScanCompletion(summary: makeSummary(cancelled: true), scheduled: false, failed: false).ranToTheEnd)
        #expect(!ScanCompletion(summary: makeSummary(), scheduled: true, failed: true).ranToTheEnd)
    }
}
