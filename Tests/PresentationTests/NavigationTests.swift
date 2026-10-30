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
        for hidden: AppDestination in [.files, .cleanup, .startup, .uninstaller, .scanner] {
            #expect(!hidden.isAvailable)
        }
        #expect(AppDestination.allCases.count == 7)
    }

    @Test func openingAHiddenDestinationRoutesToHome() {
        for hidden in AppDestination.allCases where !hidden.isAvailable {
            let fromHome = Navigation()
            fromHome.open(hidden)
            #expect(fromHome.selection == .home)

            let fromSettings = Navigation()
            fromSettings.open(.settings)
            fromSettings.open(hidden)
            #expect(fromSettings.selection == .home)
            #expect(fromSettings.selection.isAvailable)
        }
    }

    @Test func constructingWithAHiddenDestinationYieldsAVisibleSelection() {
        for destination in AppDestination.allCases {
            let navigation = Navigation(selection: destination)
            #expect(navigation.selection.isAvailable)
            #expect(navigation.selection == (destination.isAvailable ? destination : .home))
        }
    }

    @Test func sidebarListsOnlyAvailableDestinationsInOrder() {
        #expect(SidebarItem.visible.map(\.destination) == [.home, .settings])
        #expect(!SidebarItem.visible.contains { !$0.destination.isAvailable })
        #expect(SidebarItem.visible.map(\.title) == ["Home", "Settings"])
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
