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
        navigation.open(.files)
        #expect(navigation.selection == .files)
    }

    @Test func openingCurrentDestinationIsNoOp() {
        let navigation = Navigation()
        navigation.open(.files)
        navigation.open(.files)
        #expect(navigation.selection == .files)
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
