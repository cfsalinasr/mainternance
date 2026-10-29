@testable import MainternancePresentation
import Testing

struct SampleDataCopyTests {
    @Test func stringsArePinned() {
        #expect(SampleDataCopy.badgeText == "Sample data")
        #expect(SampleDataCopy.badgeAccessibilityLabel == "Sample data, not your real files")
        #expect(SampleDataCopy.sidebarMarker == "Sample")
        #expect(SampleDataCopy.settingsNote == "Not connected yet: these settings are not applied.")
    }

    @Test func onlyScreensWithoutEnginesAreMarked() {
        let marked = SidebarItem.all.filter { SampleDataCopy.isSample($0.destination) }.map(\.title)
        #expect(Set(marked) == ["Files", "Scanner", "Cleanup", "Startup", "Uninstaller"])
        #expect(!SampleDataCopy.isSample(.home))
        #expect(!SampleDataCopy.isSample(.settings))
    }

    @Test func sidebarLabelsSaySampleInWords() {
        #expect(SampleDataCopy.sidebarAccessibilityLabel(title: "Files", destination: .files) == "Files, sample data")
        #expect(SampleDataCopy.sidebarAccessibilityLabel(title: "Home", destination: .home) == "Home")
    }
}
