import Foundation
import MainternanceDomain
import ServiceManagement

public enum LoginItemError: Error, Equatable, LocalizedError {
    /// The app is not running from an app bundle, so macOS cannot open it at login.
    case unavailable
    /// macOS refused the change; carries its reason.
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .unavailable:
            "Launch at login works only when Mainternance runs as an app, ideally from the Applications folder."
        case let .failed(reason):
            "macOS could not change Launch at login: \(reason)"
        }
    }
}

/// "Launch at login" through `SMAppService.mainApp`. Unbundled (tests, `swift run`) it is unavailable and never
/// calls the system.
public struct LoginItemService: LoginItemControlling {
    private let isBundled: Bool

    public init(isBundled: Bool = Bundle.main.bundleURL.pathExtension == "app") {
        self.isBundled = isBundled
    }

    public func status() -> LoginItemStatus {
        guard isBundled else { return .unavailable }
        return Self.map(SMAppService.mainApp.status)
    }

    /// Returns the status read back after the change, which may be `requiresApproval` rather than `enabled`.
    public func setEnabled(_ enabled: Bool) throws -> LoginItemStatus {
        guard isBundled else { throw LoginItemError.unavailable }
        let service = SMAppService.mainApp
        do {
            if enabled {
                if service.status != .enabled {
                    try service.register()
                }
            } else if service.status != .notRegistered {
                try service.unregister()
            }
        } catch {
            throw LoginItemError.failed(error.localizedDescription)
        }
        return Self.map(service.status)
    }

    static func map(_ status: SMAppService.Status) -> LoginItemStatus {
        switch status {
        case .enabled: .enabled
        case .notRegistered: .disabled
        case .requiresApproval: .requiresApproval
        case .notFound: .unavailable
        @unknown default: .unavailable
        }
    }
}
