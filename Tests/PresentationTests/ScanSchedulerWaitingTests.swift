import Foundation
import MainternanceDomain
@testable import MainternancePresentation
import Testing

/// A weekly scan that cannot start is never hidden: the slot is not lost to a failed definitions update, the
/// failure stays readable, the owner is told even with the digest off, and Home does not promise "now" forever.
@MainActor
struct ScanSchedulerWaitingTests {
    private static let forty: TimeInterval = 40 * 86400

    /// freshclam damaged the database: after the update the engine has no definitions and cannot scan. The slot is
    /// given back, so the scan runs once the engine is usable again in the same week.
    @Test func anUpdateThatLeavesTheEngineUnusableGivesTheSlotBack() async {
        let rig = await SchedulerRig.make(lastRun: nil, now: utc("2026-11-04 10:00"), primed: false)
        rig.scanner.engine.configure {
            $0.status = .updateNeeded(definitionsAge: Self.forty)
            $0.statusAfterUpdate = .updateNeeded(definitionsAge: nil)
        }
        await rig.scheduler.tick()
        #expect(rig.scanner.engine.scans.isEmpty)
        rig.scanner.engine.configure { $0.status = .ready(definitionsAge: 60) }
        rig.clock.set(utc("2026-11-04 10:01"))
        await rig.scheduler.tick()
        #expect(rig.scanner.engine.scans == [.quick])
    }

    /// The scheduled update failed and the scan ran anyway: the Scanner screen still says why the update failed.
    @Test func aFailedDefinitionsUpdateStaysVisibleAfterTheScan() async {
        let rig = await SchedulerRig.make(lastRun: nil, now: utc("2026-11-04 10:00"), primed: false)
        rig.scanner.engine.configure {
            $0.status = .updateNeeded(definitionsAge: Self.forty)
            $0.updateEvents = [.failed(message: "Could not reach the download server.")]
        }
        await rig.scheduler.tick()
        #expect(rig.scanner.engine.scans == [.quick])
        #expect(rig.scanner.model.errorMessage == "The virus definitions could not be updated before the weekly scan. "
            + "Could not reach the download server.")
    }

    @Test func aScanErrorAndTheUpdateFailureAreBothShown() async {
        let rig = await SchedulerRig.make(lastRun: nil, now: utc("2026-11-04 10:00"), primed: false)
        rig.scanner.engine.configure {
            $0.status = .updateNeeded(definitionsAge: Self.forty)
            $0.updateEvents = [.failed(message: "No network.")]
            $0.scanEvents = [.started(scope: .quick), .finished(makeSummary()), .failed(message: "Scan stopped.")]
        }
        await rig.scheduler.tick()
        #expect(rig.scanner.model.errorMessage
            == "Scan stopped. The virus definitions could not be updated before the weekly scan. No network.")
    }

    // MARK: Problem alerts cover a weekly scan that could not finish

    private func notifier(alerts: Bool, digest: Bool) -> (ScanNotifier, FakeNotifications) {
        let notifications = FakeNotifications(.allowed)
        let notifier = ScanNotifier(notifications: notifications)
        var prefs = AppPreferences.defaults
        prefs.problemAlerts = alerts
        prefs.weeklyDigest = digest
        notifier.update(prefs)
        return (notifier, notifications)
    }

    @Test func withTheDigestOffAProblemAlertSaysTheWeeklyScanCouldNotFinish() async {
        let (notifier, notifications) = notifier(alerts: true, digest: false)
        await notifier.scanFailed(ScanFailure(
            found: 0, unattributedDetections: 0, scheduled: true, staleDefinitionsDays: nil
        ))
        #expect(notifications.posted == [UserNotice(
            id: "scan-findings", title: "The weekly scan could not finish",
            body: "Open Mainternance and go to Scanner to see what happened."
        )])
        let failedLate = ScanCompletion(summary: makeSummary(scanned: 7), scheduled: true, failed: true)
        await notifier.scanCompleted(failedLate)
        #expect(notifications.posted.last == UserNotice(
            id: "scan-findings", title: "Weekly scan did not finish", body: "Scanned 7 files before it stopped."
        ))
    }

    @Test func aCancelledOrManualFailureWithNothingFoundStaysQuiet() async {
        let (notifier, notifications) = notifier(alerts: true, digest: false)
        await notifier.scanCompleted(ScanCompletion(
            summary: makeSummary(cancelled: true), scheduled: true, failed: false
        ))
        await notifier.scanFailed(ScanFailure(
            found: 0, unattributedDetections: 0, scheduled: false, staleDefinitionsDays: nil
        ))
        #expect(notifications.posted.isEmpty)
        let (quiet, quietPosts) = self.notifier(alerts: false, digest: false)
        await quiet.scanFailed(ScanFailure(
            found: 0, unattributedDetections: 0, scheduled: true, staleDefinitionsDays: nil
        ))
        #expect(quietPosts.posted.isEmpty)
    }

    // MARK: Home does not promise "now" for a scan that cannot start

    @Test func aDueScanTheScannerCannotStartIsShownAsWaiting() async throws {
        let scanner = ScannerRig()
        scanner.engine.configure { $0.status = .updateNeeded(definitionsAge: nil) }
        await scanner.model.refreshStatus()
        var saved = AppPreferences.defaults
        saved.weeklyScanEnabled = true
        let store = FakePreferencesStore(saved)
        let scheduler = ScanScheduler(scanner: scanner.model, preferences: store)
        let provider = ScanAutomation.statusWithNextScan(
            FixedStatus(), scanner: scanner.model, scheduler: scheduler
        )
        let status = try #require(await provider.currentStatus())
        #expect(status.weeklyScanWaiting)
        #expect(status.nextScan == nil)
        let overview = Overview(
            snapshot: makeSnapshot(), scan: status, report: HealthReport(checks: []), actions: []
        )
        #expect(HomeModel(overview: overview).scan.next == "Weekly scan is waiting: the scanner is not ready")
        let popover = PopoverModel(overview: overview)
        #expect(popover.rows.first { $0.title == "Next scan" }?.value == "Waiting: scanner not ready")
    }

    @Test func aDueScanAReadyScannerWillStartIsNotWaiting() async throws {
        let scanner = await ScannerRig.ready()
        var saved = AppPreferences.defaults
        saved.weeklyScanEnabled = true
        let scheduler = ScanScheduler(scanner: scanner.model, preferences: FakePreferencesStore(saved))
        let provider = ScanAutomation.statusWithNextScan(FixedStatus(), scanner: scanner.model, scheduler: scheduler)
        let status = try #require(await provider.currentStatus())
        #expect(!status.weeklyScanWaiting)
        #expect(status.nextScan != nil)
    }
}

private struct FixedStatus: ScanStatusProviding {
    func currentStatus() async -> ScanStatus? {
        ScanStatus(lastScan: nil, nextScan: nil, unresolvedFindings: 0)
    }
}
