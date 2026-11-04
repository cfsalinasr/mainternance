import MainternanceDomain
import MainternancePresentation
import Testing

@MainActor
struct NavigationTests {
    @Test func defaultSelectionIsHome() {
        #expect(Navigation().selection == .home)
    }

    @Test func openSetsSelection() {
        let navigation = Navigation()
        navigation.open(.settings)
        #expect(navigation.selection == .settings)
    }

    @Test func openingCurrentDestinationIsNoOp() {
        let navigation = Navigation()
        navigation.open(.settings)
        navigation.open(.settings)
        #expect(navigation.selection == .settings)
    }

    @Test func availabilityRule() {
        #expect(AppDestination.home.isAvailable)
        #expect(AppDestination.settings.isAvailable)
        #expect(AppDestination.scanner.isAvailable)
        #expect(AppDestination.startup.isAvailable)
        #expect(AppDestination.cleanup.isAvailable)
        #expect(AppDestination.uninstaller.isAvailable)
        #expect(AppDestination.files.isAvailable)
        #expect(AppDestination.allCases.count == 7)
    }

    @Test func theScannerCanBeOpened() {
        let navigation = Navigation()
        navigation.open(.scanner)
        #expect(navigation.selection == .scanner)
    }

    @Test func openingAHiddenDestinationRoutesToHome() {
        let hide: @Sendable (AppDestination) -> Bool = { $0 != .files && $0 != .startup }
        for hidden: AppDestination in [.files, .startup] {
            let fromHome = Navigation(isAvailable: hide)
            fromHome.open(hidden)
            #expect(fromHome.selection == .home)

            let fromSettings = Navigation(isAvailable: hide)
            fromSettings.open(.settings)
            fromSettings.open(hidden)
            #expect(fromSettings.selection == .home)
        }
        let shown = Navigation(isAvailable: hide)
        shown.open(.cleanup)
        #expect(shown.selection == .cleanup)
    }

    @Test func constructingWithAHiddenDestinationYieldsHome() {
        let hide: @Sendable (AppDestination) -> Bool = { $0 != .files }
        #expect(Navigation(selection: .files, isAvailable: hide).selection == .home)
        #expect(Navigation(selection: .scanner, isAvailable: hide).selection == .scanner)
        for destination in AppDestination.allCases {
            #expect(Navigation(selection: destination).selection == destination)
        }
    }

    @Test func sidebarListsOnlyAvailableDestinationsInOrder() {
        #expect(SidebarItem.visible.map(\.destination) == [
            .home, .cleanup, .files, .scanner, .startup, .uninstaller, .settings
        ])
        #expect(!SidebarItem.visible.contains { !$0.destination.isAvailable })
        #expect(SidebarItem.visible.map(\.title) == [
            "Home", "Cleanup", "Files", "Scanner", "Startup", "Uninstaller", "Settings"
        ])
    }

    @Test func sidebarOrderAndSymbols() {
        #expect(SidebarItem.all.map(\.destination) == [
            .home, .cleanup, .files, .scanner, .startup, .uninstaller, .settings
        ])
        #expect(SidebarItem.all.map(\.symbol) == [
            "house", "sparkles", "magnifyingglass", "shield", "power", "trash", "gearshape"
        ])
        #expect(SidebarItem.all.map(\.title) == [
            "Home", "Cleanup", "Files", "Scanner", "Startup", "Uninstaller", "Settings"
        ])
    }
}
