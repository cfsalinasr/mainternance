import MainternanceDomain
import Observation

/// Which section the main window shows. Banner reasons, suggested actions and tiles call `open`.
@MainActor
@Observable
public final class Navigation {
    /// Only `init(selection:)` and `open(_:)` write it, so a hidden screen can never be selected.
    /// Popover rows and metrics carry no destinations (only Home links do), so they need no such rule.
    public private(set) var selection: AppDestination = .home

    /// A hidden initial destination (for example a restored one) becomes Home.
    public init(selection: AppDestination = .home) {
        self.selection = selection.isAvailable ? selection : .home
    }

    /// A destination without a working engine is never selected: opening one routes to Home.
    public func open(_ destination: AppDestination) {
        let target = destination.isAvailable ? destination : .home
        guard target != selection else { return }
        selection = target
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

    /// The items the sidebar shows: only destinations that are available, in sidebar order.
    public static var visible: [SidebarItem] {
        all.filter(\.destination.isAvailable)
    }

    public static func item(for destination: AppDestination) -> SidebarItem {
        all.first { $0.destination == destination } ?? all[0]
    }
}
