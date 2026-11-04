@testable import MainternancePresentation
import Testing

struct SettingsRefreshNoteTests {
    @Test func settingsRefreshNoteMentionsLowPowerMode() {
        #expect(SettingsView.refreshNote == [
            "Metrics refresh every 2 s while this window or the menu bar popover is open,",
            "and about every 45 s otherwise; both intervals double in Low Power Mode."
        ].joined(separator: " "))
    }
}
