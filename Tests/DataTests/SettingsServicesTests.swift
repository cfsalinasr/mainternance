import Foundation
@testable import MainternanceData
import MainternanceDomain
import ServiceManagement
import Testing
import UserNotifications

/// Tests run unbundled: both services must report "unavailable" and never touch the system services.
@Suite("Settings services")
struct SettingsServicesTests {
    @Test("unbundled, the login item is unavailable and enabling it throws a readable error")
    func loginItemUnbundled() {
        let service = LoginItemService(isBundled: false)
        #expect(service.status() == .unavailable)
        #expect(throws: LoginItemError.unavailable) { try service.setEnabled(true) }
        #expect(throws: LoginItemError.unavailable) { try service.setEnabled(false) }
        let message = LoginItemError.unavailable.errorDescription ?? ""
        #expect(message.contains("Applications"))
    }

    @Test("the default reads the running bundle; the test runner is not an app")
    func defaultIsNotBundledInTests() {
        #expect(LoginItemService().status() == .unavailable)
    }

    @Test("macOS login item states map to the app's states")
    func loginItemMapping() {
        #expect(LoginItemService.map(.enabled) == .enabled)
        #expect(LoginItemService.map(.notRegistered) == .disabled)
        #expect(LoginItemService.map(.requiresApproval) == .requiresApproval)
        #expect(LoginItemService.map(.notFound) == .unavailable)
    }

    @Test("unbundled, notifications are unavailable and posting does nothing")
    func notificationsUnbundled() async {
        let service = UserNotificationService(isBundled: false)
        #expect(await service.authorization() == .unavailable)
        #expect(await service.requestAuthorization() == .unavailable)
        await service.post(UserNotice(id: "scan-findings", title: "Title", body: "Body"))
        #expect(await UserNotificationService().authorization() == .unavailable)
    }

    @Test("macOS notification permission maps to the app's states")
    func notificationMapping() {
        #expect(UserNotificationService.map(.notDetermined) == .notDetermined)
        #expect(UserNotificationService.map(.denied) == .denied)
        #expect(UserNotificationService.map(.authorized) == .allowed)
        #expect(UserNotificationService.map(.provisional) == .allowed)
    }
}
