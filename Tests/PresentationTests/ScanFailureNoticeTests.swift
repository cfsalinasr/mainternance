import Foundation
import MainternanceDomain
@testable import MainternancePresentation
import Testing

/// Scans that end without a summary still notify, and old definitions are never hidden behind "nothing found".
@MainActor
struct ScanFailureNoticeTests {
    private func notifier(alerts: Bool = true, digest: Bool = true) -> (ScanNotifier, FakeNotifications) {
        let notifications = FakeNotifications(.allowed)
        let notifier = ScanNotifier(notifications: notifications)
        var prefs = AppPreferences.defaults
        prefs.problemAlerts = alerts
        prefs.weeklyDigest = digest
        notifier.update(prefs)
        return (notifier, notifications)
    }

    private func failure(
        found: Int = 0, unattributed: Int = 0, scheduled: Bool = true, stale: Int? = nil
    ) -> ScanFailure {
        ScanFailure(
            found: found,
            unattributedDetections: unattributed,
            scheduled: scheduled,
            staleDefinitionsDays: stale
        )
    }

    // MARK: The Scanner model reports the failure

    /// clamscan crashed after it reported two files: the failure is reported with that count.
    @Test func aScanThatStartedAndFailedWithoutASummaryIsReported() async {
        let rig = await ScannerRig.ready()
        let seen = Recorded<ScanFailure>()
        rig.model.onScanFailed = { seen.add($0) }
        rig.engine.configure {
            $0.scanEvents = [
                .started(scope: .quick), .found(makeFinding(1)), .found(makeFinding(2)), .unattributed(detections: 1),
                .failed(message: "clamscan stopped: signal 11 at /Users/someone/Downloads/file1.bin")
            ]
        }
        await rig.model.startScan(.quick)
        #expect(seen.all == [ScanFailure(
            found: 2,
            unattributedDetections: 1,
            scheduled: false,
            staleDefinitionsDays: nil
        )])
    }

    @Test func aScanRefusedBeforeItStartedIsNotReportedAsAFailedScan() async {
        let rig = await ScannerRig.ready()
        let seen = Recorded<ScanFailure>()
        rig.model.onScanFailed = { seen.add($0) }
        rig.engine.configure { $0.scanEvents = [.failed(message: "engine is not ready")] }
        await rig.model.startScan(.quick)
        #expect(seen.all.isEmpty)
    }

    @Test func aFailedScanWithASummaryIsReportedOnceAsACompletion() async {
        let rig = await ScannerRig.ready()
        let failures = Recorded<ScanFailure>()
        rig.model.onScanFailed = { failures.add($0) }
        rig.engine.configure {
            $0.scanEvents = [.started(scope: .quick), .finished(makeSummary()), .failed(message: "stopped")]
        }
        await rig.model.startScan(.quick)
        #expect(failures.all.isEmpty) // `onScanCompleted` carries it, with `failed`
    }

    // MARK: Wording

    @Test func aFailedWeeklyScanSaysItCouldNotFinish() async {
        let (notifier, notifications) = notifier()
        await notifier.scanFailed(failure())
        await notifier.scanFailed(failure(found: 2))
        #expect(notifications.posted == [
            UserNotice(
                id: "weekly-digest", title: "The weekly scan could not finish",
                body: "Open Mainternance and go to Scanner to see what happened."
            ),
            UserNotice(
                id: "weekly-digest", title: "The weekly scan could not finish",
                body: "It found 2 files before it stopped. Open Mainternance and go to Scanner to review them."
            )
        ])
    }

    @Test func aFailedScanWithFindingsAlertsWhenThereIsNoDigest() async {
        let (manual, manualPosts) = notifier()
        await manual.scanFailed(failure(found: 1, unattributed: 1, scheduled: false))
        await manual.scanFailed(failure(scheduled: false)) // nothing found: no alert
        #expect(manualPosts.posted == [UserNotice(
            id: "scan-findings", title: "Mainternance found 1 file and 1 detection to review",
            body: "The scan did not finish. Open Mainternance and go to Scanner to review them."
        )])
        let (noDigest, noDigestPosts) = notifier(digest: false)
        await noDigest.scanFailed(failure(found: 3))
        #expect(noDigestPosts.posted.map(\.id) == ["scan-findings"])
        let (quiet, quietPosts) = notifier(alerts: false, digest: false)
        await quiet.scanFailed(failure(found: 3))
        #expect(quietPosts.posted.isEmpty)
    }

    @Test func staleDefinitionsNeverSayNothingFound() async {
        let (notifier, notifications) = notifier()
        let clean = ScanCompletion(
            summary: makeSummary(scanned: 80), scheduled: true, failed: false, staleDefinitionsDays: 40
        )
        await notifier.scanCompleted(clean)
        #expect(notifications.posted == [UserNotice(
            id: "weekly-digest", title: "Weekly scan finished with old virus definitions",
            body: "Scanned 80 files. The virus definitions are 40 days old, so newer threats may be missed."
        )])
        let found = ScanCompletion(
            summary: makeSummary(scanned: 80, findings: 1), scheduled: true, failed: false, staleDefinitionsDays: 1
        )
        await notifier.scanCompleted(found)
        #expect(notifications.posted.last?.body == "Scanned 80 files. The virus definitions are 1 day old, "
            + "so newer threats may be missed. Open Mainternance and go to Scanner to review them.")
        await notifier.scanFailed(failure(stale: 9))
        #expect(notifications.posted.last?.body == "The virus definitions are 9 days old. "
            + "Open Mainternance and go to Scanner to see what happened.")
        #expect(notifications.posted.allSatisfy { !$0.title.contains("nothing") })
    }

    // MARK: Through the automation

    @Test func aScheduledScanThatCrashesNotifies() async {
        let rig = await AutomationRig.make()
        rig.scanner.engine.configure {
            $0.scanEvents = [.started(scope: .quick), .found(makeFinding(1)), .failed(message: "segfault in file1.bin")]
        }
        await rig.settings.load()
        await rig.automation.scheduler.tick()
        await rig.notificationsSent()
        #expect(rig.notifications.posted.map(\.title) == ["The weekly scan could not finish"])
        #expect(rig.notifications.posted.allSatisfy { !$0.body.contains("segfault") && !$0.body.contains(".bin") })
    }

    /// The launch check reads the engine status without the Scanner screen opening.
    @Test func startChecksTheEngineOnce() async {
        let scanner = ScannerRig()
        let store = FakePreferencesStore()
        let notifications = FakeNotifications(.allowed)
        let settings = SettingsViewState(preferences: store, loginItem: FakeLoginItem(), notifications: notifications)
        let automation = ScanAutomation(
            scanner: scanner.model, settings: settings,
            scheduler: ScanScheduler(
                scanner: scanner.model, preferences: store, sleep: { _ in try await Task.sleep(for: .seconds(3600)) }
            ),
            notifier: ScanNotifier(notifications: notifications)
        )
        #expect(scanner.model.engine == nil)
        automation.start()
        await automation.launchCheck?.value
        automation.stop()
        #expect(scanner.model.engine == .ready(definitionsAge: 60))
    }
}
