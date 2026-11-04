@testable import MainternancePresentation
import Testing

struct SampleDataCopyTests {
    @Test func stringsArePinned() {
        #expect(SampleDataCopy.badgeText == "Sample data")
        #expect(SampleDataCopy.badgeAccessibilityLabel == "Sample data, not your real files")
        #expect(SampleDataCopy.sidebarMarker == "Sample")
    }

    @Test func settingsRefreshNoteMentionsLowPowerMode() {
        #expect(SettingsView.refreshNote == [
            "Metrics refresh every 2 s while this window or the menu bar popover is open,",
            "and about every 45 s otherwise; both intervals double in Low Power Mode."
        ].joined(separator: " "))
    }

    @Test func onlyScreensWithoutEnginesAreMarked() {
        let marked = SidebarItem.all.filter { SampleDataCopy.isSample($0.destination) }.map(\.title)
        #expect(Set(marked) == ["Files"])
        #expect(!SampleDataCopy.isSample(.cleanup))
        #expect(!SampleDataCopy.isSample(.home))
        #expect(!SampleDataCopy.isSample(.settings))
        #expect(!SampleDataCopy.isSample(.scanner))
        #expect(!SampleDataCopy.isSample(.startup))
    }

    @Test func sidebarLabelsSaySampleInWords() {
        #expect(SampleDataCopy.sidebarAccessibilityLabel(title: "Files", destination: .files) == "Files, sample data")
        #expect(SampleDataCopy.sidebarAccessibilityLabel(title: "Home", destination: .home) == "Home")
    }
}
