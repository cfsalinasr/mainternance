import Foundation
import MainternanceDomain
@testable import MainternancePresentation
import Testing

/// Launch at login and notification permission: Settings shows what macOS reports and says where to change it.
@MainActor
struct SettingsStatusTests {
    // MARK: Launch at login

    @Test func launchAtLoginFollowsTheReturnedStatus() async {
        let rig = SettingsRig()
        await rig.state.setLaunchAtLogin(true)
        #expect(rig.login.requests == [true])
        #expect(rig.state.launchAtLogin)
        #expect(rig.store.stored.launchAtLogin)
        #expect(rig.state.message == nil)
        await rig.state.setLaunchAtLogin(false)
        #expect(!rig.state.launchAtLogin)
        #expect(!rig.store.stored.launchAtLogin)
    }

    /// Registered but waiting for approval: the toggle shows ON (macOS has the request) with a note saying where
    /// to approve, so the owner can also turn it off again, which unregisters it.
    @Test func approvalNeededShowsTheToggleOnAndSaysWhere() async {
        let rig = SettingsRig()
        rig.login.configure { $0.resultStatus = .requiresApproval }
        await rig.state.setLaunchAtLogin(true)
        #expect(rig.state.loginStatus == .requiresApproval)
        #expect(rig.state.launchAtLogin)
        #expect(rig.state.current.launchAtLogin)
        #expect(rig.store.stored.launchAtLogin)
        let message = rig.state.message ?? ""
        #expect(message.contains("System Settings > General > Login Items"))
        #expect(rig.state.notes == [message]) // said once, not twice
        rig.login.configure { $0.resultStatus = nil }
        await rig.state.setLaunchAtLogin(false)
        #expect(rig.login.requests == [true, false])
        #expect(rig.state.loginStatus == .disabled)
        #expect(!rig.state.launchAtLogin)
        #expect(!rig.store.stored.launchAtLogin)
        #expect(rig.state.notes.isEmpty)
    }

    @Test func approvalNeededAtLoadShowsTheToggleOnWithTheNote() async {
        let rig = SettingsRig()
        rig.login.configure { $0.status = .requiresApproval }
        await rig.state.load()
        #expect(rig.state.launchAtLogin)
        #expect(rig.state.notes == [SettingsText.loginApproval])
    }

    /// The owner approved it in System Settings: coming back to the app must not keep the stale note.
    @Test func refreshStatusClearsAStaleApprovalNote() async {
        let rig = SettingsRig()
        rig.login.configure { $0.resultStatus = .requiresApproval }
        await rig.state.setLaunchAtLogin(true)
        await rig.state.refreshStatus() // still waiting: the note stays
        #expect(rig.state.notes == [SettingsText.loginApproval])
        rig.login.configure { $0.status = .enabled }
        await rig.state.refreshStatus()
        #expect(rig.state.message == nil)
        #expect(rig.state.notes.isEmpty)
        #expect(rig.state.launchAtLogin)
        #expect(rig.store.saves.count == 1) // refreshing writes nothing
    }

    @Test func refreshStatusKeepsAMessageThatIsNotAboutApproval() async {
        let rig = SettingsRig()
        rig.login.configure { $0.fails = true }
        await rig.state.setLaunchAtLogin(true)
        await rig.state.refreshStatus()
        #expect(rig.state.message == "macOS could not change Launch at login: test refusal")
    }

    @Test func aRefusalShowsItsMessageAndLeavesTheToggleOff() async {
        let rig = SettingsRig()
        rig.login.configure { $0.fails = true }
        await rig.state.setLaunchAtLogin(true)
        #expect(!rig.state.launchAtLogin)
        #expect(!rig.store.stored.launchAtLogin)
        #expect(rig.state.message == "macOS could not change Launch at login: test refusal")
    }

    @Test func unavailableLoginItemIsExplained() async {
        let rig = SettingsRig()
        rig.login.configure { $0.status = .unavailable }
        await rig.state.load()
        #expect(!rig.state.launchAtLogin)
        #expect(rig.state.loginWarning == SettingsText.loginUnavailable)
        #expect(rig.state.notes.contains(SettingsText.loginUnavailable))
    }

    // MARK: Notifications

    @Test func turningOnAlertsAsksForPermissionOnce() async {
        var stored = AppPreferences.defaults
        stored.problemAlerts = false
        stored.weeklyDigest = false
        let rig = SettingsRig(stored: stored)
        await rig.state.load()
        await rig.state.setProblemAlerts(true)
        await rig.state.setWeeklyDigest(true)
        #expect(rig.notifications.requests == 1)
        #expect(rig.state.notificationAuthorization == .allowed)
        #expect(rig.state.notificationWarning == nil)
    }

    @Test func permissionIsNotAskedWhenAlreadyDecidedOrWhenTurningOff() async {
        let rig = SettingsRig(authorization: .allowed)
        await rig.state.load()
        await rig.state.setProblemAlerts(false)
        await rig.state.setProblemAlerts(true)
        #expect(rig.notifications.requests == 0)
        let undecided = SettingsRig()
        await undecided.state.load()
        await undecided.state.setWeeklyDigest(false)
        #expect(undecided.notifications.requests == 0)
    }

    @Test func deniedPermissionSavesTheChoiceAndWarnsWhereToAllow() async {
        var stored = AppPreferences.defaults
        stored.problemAlerts = false
        let rig = SettingsRig(stored: stored)
        rig.notifications.configure { $0.answer = .denied }
        await rig.state.load()
        await rig.state.setProblemAlerts(true)
        #expect(rig.store.stored.problemAlerts)
        #expect(rig.state.current.problemAlerts)
        #expect(rig.state.notificationAuthorization == .denied)
        let warning = rig.state.notificationWarning ?? ""
        #expect(warning.contains("System Settings > Notifications"))
        #expect(rig.state.notes.contains(warning))
        #expect(rig.state.notes.count == Set(rig.state.notes).count)
    }

    /// A fresh install has both toggles on and has never been asked: Settings says so and offers the request,
    /// but never asks by itself.
    @Test func undecidedPermissionWithTogglesOnShowsTheAllowNote() async {
        let rig = SettingsRig()
        #expect(rig.state.notificationPermissionNote == nil) // not read yet: nothing claimed
        await rig.state.load()
        #expect(rig.state.notificationPermissionNote == SettingsText.allowNotifications)
        #expect(rig.notifications.requests == 0)
        await rig.state.requestNotificationPermission()
        #expect(rig.notifications.requests == 1)
        #expect(rig.state.notificationAuthorization == .allowed)
        #expect(rig.state.notificationPermissionNote == nil)
        #expect(rig.state.notificationWarning == nil)
    }

    @Test func refusingFromTheAllowNoteShowsWhereToAllow() async {
        let rig = SettingsRig()
        rig.notifications.configure { $0.answer = .denied }
        await rig.state.load()
        await rig.state.requestNotificationPermission()
        #expect(rig.state.notificationPermissionNote == nil)
        #expect(rig.state.notificationWarning == SettingsText.notificationsDenied)
    }

    @Test func noAllowNoteWhenBothTogglesAreOffOrPermissionIsDecided() async {
        var stored = AppPreferences.defaults
        stored.problemAlerts = false
        stored.weeklyDigest = false
        let off = SettingsRig(stored: stored)
        await off.state.load()
        #expect(off.state.notificationPermissionNote == nil)
        let allowed = SettingsRig(authorization: .allowed)
        await allowed.state.load()
        #expect(allowed.state.notificationPermissionNote == nil)
    }

    /// Turning the weekly scan on re-reads the permission, so the note shows even if Settings was not loaded.
    @Test func turningTheWeeklyScanOnShowsTheAllowNoteWhenUndecided() async {
        let rig = SettingsRig()
        await rig.state.setWeeklyScanEnabled(true)
        #expect(rig.state.notificationPermissionNote == SettingsText.allowNotifications)
        #expect(rig.notifications.requests == 0)
    }

    @Test func noNotificationWarningWhenBothNotificationTogglesAreOff() async {
        var stored = AppPreferences.defaults
        stored.problemAlerts = false
        stored.weeklyDigest = false
        let rig = SettingsRig(stored: stored, authorization: .denied)
        await rig.state.load()
        #expect(rig.state.notificationWarning == nil)
        let unavailable = SettingsRig(authorization: .unavailable)
        await unavailable.state.load()
        #expect(unavailable.state.notificationWarning == SettingsText.notificationsUnavailable)
    }
}
