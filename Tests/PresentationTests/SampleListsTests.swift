import Foundation
@testable import MainternancePresentation
import Testing

@MainActor
struct SampleListsTests {
    @Test func sumIgnoresNegatives() {
        #expect(SampleLists.sum([5, -3, 2]) == 7)
        #expect(SampleLists.sum([]) == 0)
    }

    @Test func sharedByteFormatterCoversUnitsAndZero() {
        #expect(formatBytes(41_000_000_000) == "41 GB")
        #expect(formatBytes(240_000_000) == "240 MB")
        #expect(formatBytes(12000) == "12 KB")
        #expect(formatBytes(0).contains("0"))
        #expect(!formatBytes(0).localizedCaseInsensitiveContains("zero"))
        #expect(formatBytes(-5) == formatBytes(0))
    }
}

@MainActor
struct WindowStatesTests {
    @Test func constructsAllStates() {
        let states = WindowStates(
            scanner: ScannerRig().model, settings: SettingsRig().state, startup: StartupRig().state,
            cleanup: CleanupRig().state, uninstaller: UninstallerRig().state
        )
        #expect(!states.files.files.isEmpty)
        #expect(states.scanner.findings.isEmpty) // The real Scanner starts with nothing listed, never sample data.
        #expect(states.cleanup.measurement == nil) // the real Cleanup screen shows nothing until it has measured
        #expect(states.startup.snapshot == nil) // the real Startup screen lists nothing until it has read the Mac
        #expect(states.uninstaller.apps.isEmpty) // the real Uninstaller lists nothing until its screen appears
        #expect(states.settings.current == .defaults)
    }
}
