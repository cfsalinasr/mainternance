import Foundation
import MainternanceDomain
import UserNotifications

/// Notifications through `UNUserNotificationCenter`. Unbundled (tests, `swift run`) the center must not be touched
/// (it crashes without a bundle), so everything reports `unavailable` and posting does nothing.
public final class UserNotificationService: NotificationPosting, Sendable {
    private let isBundled: Bool

    public init(isBundled: Bool = Bundle.main.bundleURL.pathExtension == "app") {
        self.isBundled = isBundled
    }

    public func authorization() async -> NotificationAuthorization {
        guard isBundled else { return .unavailable }
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        return Self.map(settings.authorizationStatus)
    }

    public func requestAuthorization() async -> NotificationAuthorization {
        guard isBundled else { return .unavailable }
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert])
        return await authorization()
    }

    /// Posts at once; a notice with the same id replaces the earlier one. Silent (no sound).
    public func post(_ notice: UserNotice) async {
        guard isBundled, await authorization() == .allowed else { return }
        let content = UNMutableNotificationContent()
        content.title = notice.title
        content.body = notice.body
        content.sound = nil
        let request = UNNotificationRequest(identifier: notice.id, content: content, trigger: nil)
        try? await UNUserNotificationCenter.current().add(request)
    }

    static func map(_ status: UNAuthorizationStatus) -> NotificationAuthorization {
        switch status {
        case .notDetermined: .notDetermined
        case .denied: .denied
        case .authorized, .provisional: .allowed
        @unknown default: .unavailable
        }
    }
}
