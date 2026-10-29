import MainternanceDomain
import Observation

/// Which section the main window shows. Banner reasons, suggested actions and tiles call `open`.
@MainActor
@Observable
public final class Navigation {
    public var selection: AppDestination = .home

    public init() {}

    public func open(_ destination: AppDestination) {
        guard destination != selection else { return }
        selection = destination
    }
}

public struct SidebarItem: Equatable, Sendable, Identifiable {
    public var id: AppDestination {
        destination
    }

    public var destination: AppDestination
    public var title: String
    public var symbol: String

    /// Sidebar order as approved.
    public static let all: [SidebarItem] = [
        SidebarItem(destination: .home, title: "Home", symbol: "house"),
        SidebarItem(destination: .cleanup, title: "Cleanup", symbol: "sparkles"),
        SidebarItem(destination: .files, title: "Files", symbol: "magnifyingglass"),
        SidebarItem(destination: .scanner, title: "Scanner", symbol: "shield"),
        SidebarItem(destination: .startup, title: "Startup", symbol: "power"),
        SidebarItem(destination: .uninstaller, title: "Uninstaller", symbol: "trash"),
        SidebarItem(destination: .settings, title: "Settings", symbol: "gearshape")
    ]

    public static func item(for destination: AppDestination) -> SidebarItem {
        all.first { $0.destination == destination } ?? all[0]
    }
}
