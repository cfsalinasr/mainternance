import Foundation
import MainternanceDomain
@testable import MainternancePresentation
import Testing

/// The weekly scan runs without the Scanner screen ever opening, notices an engine that changed meanwhile, keeps
/// its definitions fresh, and does not lose the week to a scan that never started.
@MainActor
struct ScanSchedulerReadinessTests {
    private static let forty: TimeInterval = 40 * 86400

    /// Launch at login with the window closed: nothing ever asked the engine for its status before the tick.
    @Test func aDueScanRunsWhenTheScannerScreenWasNeverOpened() async {
        let rig = await SchedulerRig.make(lastRun: nil, now: utc("2026-11-04 10:00"), primed: false)
        #expect(rig.scanner.model.engine == nil)
        await rig.scheduler.tick()
        #expect(rig.scanner.engine.scans == [.quick])
        #expect(rig.finished.all == [makeSummary(scope: .quick, scanned: 12)])
    }

    /// The screen saw a ready engine once; ClamAV was removed later. The slot is not used up on a scan that
    /// cannot run.
    @Test func anEngineRemovedSinceTheScreenLookedIsNoticedBeforeTheSlotIsUsed() async {
        let rig = await SchedulerRig.make(lastRun: nil, now: utc("2026-11-04 10:00"))
        rig.scanner.engine.configure { $0.status = .notInstalled }
        await rig.scheduler.tick()
        #expect(rig.scanner.engine.scans.isEmpty)
        #expect(rig.store.saves.isEmpty)
        #expect(rig.scanner.model.engine == .notInstalled)
    }

    @Test func staleDefinitionsAreUpdatedBeforeTheScheduledScan() async {
        let rig = await SchedulerRig.make(lastRun: nil, now: utc("2026-11-04 10:00"), primed: false)
        let completions = Recorded<ScanCompletion>()
        rig.scanner.model.onScanCompleted = { completions.add($0) }
        rig.scanner.engine.configure {
            $0.status = .updateNeeded(definitionsAge: Self.forty)
            $0.statusAfterUpdate = .ready(definitionsAge: 60)
        }
        await rig.scheduler.tick()
        #expect(rig.scanner.log.all == ["save", "update", "scan"])
        #expect(completions.all.map(\.staleDefinitionsDays) == [nil])
    }

    /// The update failed: the scan still runs, and its result says how old the definitions are.
    @Test func definitionsThatStayStaleAreCarriedIntoTheResult() async {
        let rig = await SchedulerRig.make(lastRun: nil, now: utc("2026-11-04 10:00"), primed: false)
        let completions = Recorded<ScanCompletion>()
        rig.scanner.model.onScanCompleted = { completions.add($0) }
        rig.scanner.engine.configure {
            $0.status = .updateNeeded(definitionsAge: Self.forty)
            $0.updateEvents = [.failed(message: "no network")]
        }
        await rig.scheduler.tick()
        #expect(rig.scanner.engine.scans == [.quick])
        #expect(completions.all.map(\.staleDefinitionsDays) == [40])
        #expect(completions.all.map(\.scheduled) == [true])
    }

    @Test func freshDefinitionsAreNotUpdated() async {
        let rig = await SchedulerRig.make(lastRun: nil, now: utc("2026-11-04 10:00"), primed: false)
        await rig.scheduler.tick()
        #expect(!rig.scanner.log.all.contains("update"))
    }

    /// The engine refused the scan before it started: the slot is given back once (a retry at the next tick), and
    /// not again, so a scanner that always refuses cannot start a scan every minute.
    @Test func aScanThatFailsBeforeItStartsGivesTheSlotBackOnce() async {
        let rig = await SchedulerRig.make(lastRun: nil, now: utc("2026-11-04 10:00"))
        rig.scanner.engine.configure { $0.scanEvents = [.failed(message: "engine is not ready")] }
        await rig.scheduler.tick()
        #expect(rig.scanner.engine.scans == [.quick])
        rig.clock.set(utc("2026-11-04 10:01"))
        await rig.scheduler.tick()
        #expect(rig.scanner.engine.scans == [.quick, .quick])
        rig.clock.set(utc("2026-11-04 10:02"))
        await rig.scheduler.tick()
        #expect(rig.scanner.engine.scans == [.quick, .quick])
    }

    /// Settings pushes values carrying the run recorded on disk; the slot given back stays given back.
    @Test func theGivenBackSlotSurvivesASettingsChange() async {
        let moment = utc("2026-11-04 10:00")
        let rig = await SchedulerRig.make(lastRun: nil, now: moment)
        rig.scanner.engine.configure { $0.scanEvents = [.failed(message: "engine is not ready")] }
        await rig.scheduler.tick()
        var pushed = rig.prefs
        pushed.lastScheduledRun = moment
        rig.scheduler.update(pushed)
        rig.scanner.engine.configure {
            $0.scanEvents = [.started(scope: .quick), .finished(makeSummary(scope: .quick, scanned: 12))]
        }
        rig.clock.set(utc("2026-11-04 10:01"))
        await rig.scheduler.tick()
        #expect(rig.scanner.engine.scans == [.quick, .quick])
        #expect(rig.finished.all.count == 1)
    }

    /// A scan that started and then failed is a real run: the slot stays used.
    @Test func aScanThatStartedAndFailedKeepsTheSlot() async {
        let rig = await SchedulerRig.make(lastRun: nil, now: utc("2026-11-04 10:00"))
        rig.scanner.engine.configure { $0.scanEvents = [.started(scope: .quick), .failed(message: "crashed")] }
        await rig.scheduler.tick()
        rig.clock.set(utc("2026-11-04 10:01"))
        await rig.scheduler.tick()
        #expect(rig.scanner.engine.scans == [.quick])
    }

    @Test func knownPreferencesAreTheSchedulersAndLoadedUntilThen() async {
        var saved = AppPreferences.defaults
        saved.weeklyScanEnabled = true
        let store = FakePreferencesStore(saved)
        let scanner = ScannerRig()
        let scheduler = ScanScheduler(scanner: scanner.model, preferences: store, calendar: utcCalendar)
        #expect(await scheduler.weeklyPreferences().weeklyScanEnabled) // before Settings loaded: read from disk
        scheduler.update(.defaults)
        store.configure { $0.stored = saved }
        #expect(await !scheduler.weeklyPreferences().weeklyScanEnabled) // then: what the scheduler holds
    }
}
