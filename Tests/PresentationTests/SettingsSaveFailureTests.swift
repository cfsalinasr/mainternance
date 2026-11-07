import Foundation
import MainternanceDomain
@testable import MainternancePresentation
import Testing

/// A setting or a recorded run that could not be written is never silent: Settings says so until a later write
/// works.
@MainActor
struct SettingsSaveFailureTests {
    @Test func aChangeThatCouldNotBeSavedSaysSo() async {
        let rig = SettingsRig()
        await rig.state.load()
        rig.store.configure { $0.failWrites = true }
        await rig.state.setWeeklyScanEnabled(true)
        #expect(rig.state.current.weeklyScanEnabled) // shown for this session...
        #expect(rig.store.stored.weeklyScanEnabled == false) // ...but not on disk
        #expect(rig.state.saveFailed)
        #expect(rig.state.notes.contains(SettingsText.notSaved))
    }

    @Test func theNoteGoesOnceALaterChangeIsSaved() async {
        let rig = SettingsRig()
        await rig.state.load()
        rig.store.configure { $0.failWrites = true }
        await rig.state.setWeeklyDigest(false)
        #expect(rig.state.notes.contains(SettingsText.notSaved))
        rig.store.configure { $0.failWrites = false }
        await rig.state.setWeeklyDigest(false)
        #expect(!rig.state.saveFailed)
        #expect(!rig.state.notes.contains(SettingsText.notSaved))
        #expect(rig.store.stored.weeklyDigest == false)
    }

    @Test func aLaterSaveOfAnotherSettingKeepsTheFailedChange() async {
        let rig = SettingsRig()
        await rig.state.load()
        rig.store.configure { $0.failWrites = true }
        await rig.state.setWeeklyDigest(false)
        rig.store.configure { $0.failWrites = false }
        await rig.state.setProblemAlerts(false)
        #expect(!rig.state.saveFailed)
        #expect(rig.store.stored.weeklyDigest == false)
        #expect(rig.store.stored.problemAlerts == false)
        #expect(rig.state.current.weeklyDigest == false)
        #expect(rig.state.current.problemAlerts == false)
    }

    @Test func aSavedChangeShowsNoNote() async {
        let rig = SettingsRig()
        await rig.state.load()
        await rig.state.setProblemAlerts(false)
        #expect(!rig.state.saveFailed)
        #expect(!rig.state.notes.contains(SettingsText.notSaved))
    }

    @Test func aScheduledRunThatCouldNotBeSavedIsShownInSettings() async {
        let rig = await AutomationRig.make()
        rig.finishWith(findings: 0)
        await rig.settings.load()
        rig.store.configure { $0.failWrites = true }
        await rig.automation.scheduler.tick()
        #expect(rig.scanner.engine.scans == [.quick]) // the scan still runs, once
        #expect(rig.settings.scheduledRunSaveFailed)
        #expect(rig.settings.notes.contains(SettingsText.scheduledRunNotSaved))
        // Held in memory: the same slot does not run again in this session.
        await rig.automation.scheduler.tick()
        #expect(rig.scanner.engine.scans == [.quick])
    }

    @Test func aScheduledRunThatWasSavedShowsNoNote() async {
        let rig = await AutomationRig.make()
        rig.finishWith(findings: 0)
        await rig.settings.load()
        await rig.automation.scheduler.tick()
        #expect(rig.scanner.engine.scans == [.quick])
        #expect(!rig.settings.scheduledRunSaveFailed)
        #expect(!rig.settings.notes.contains(SettingsText.scheduledRunNotSaved))
    }

    @Test func afterAReadErrorAtLaunchTheScreenFollowsWhatWasSaved() async {
        var onDisk = AppPreferences.defaults
        onDisk.weeklyScanEnabled = true
        onDisk.schedule = ScanSchedule(weekday: 5, hour: 21, minute: 45)
        onDisk.weeklyDigest = false
        let rig = SettingsRig(stored: onDisk)
        rig.store.configure { $0.failLoads = true }
        await rig.state.load()
        #expect(rig.state.current == .defaults) // the launch read failed
        await rig.state.setProblemAlerts(false)
        var expected = onDisk
        expected.problemAlerts = false
        #expect(rig.store.stored == expected) // the change went on top of the real file
        #expect(rig.state.current == expected) // and the screen now shows it, not the defaults
        #expect(rig.changed.last == expected) // the scheduler and the notifier follow it too
        #expect(rig.state.scheduleControlsEnabled)
    }

    @Test func aWriteThatSavedWhatIsShownReportsNothingMore() async {
        let rig = SettingsRig()
        await rig.state.load()
        await rig.state.setProblemAlerts(false)
        #expect(rig.changed.count == 2) // the load and the change; adopting equal values says nothing new
    }

    @Test func theSaveNotesAreWorded() {
        #expect(SettingsText.notSaved.hasPrefix("Your setting could not be saved."))
        #expect(SettingsText.scheduledRunNotSaved.contains("may run again"))
    }
}
