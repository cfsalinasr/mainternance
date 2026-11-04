@testable import MainternancePresentation
import Testing

@MainActor
struct WindowStatesTests {
    @Test func constructsAllStates() {
        let states = WindowStates(
            scanner: ScannerRig().model, settings: SettingsRig().state, startup: StartupRig().state,
            cleanup: CleanupRig().state, uninstaller: UninstallerRig().state, files: FilesRig().state
        )
        #expect(states.files.searchResults.isEmpty) // the real Files screen finds nothing until asked
        #expect(states.files.diskResult == nil)
        #expect(states.scanner.findings.isEmpty) // The real Scanner starts with nothing listed, never sample data.
        #expect(states.cleanup.measurement == nil) // the real Cleanup screen shows nothing until it has measured
        #expect(states.startup.snapshot == nil) // the real Startup screen lists nothing until it has read the Mac
        #expect(states.uninstaller.apps.isEmpty) // the real Uninstaller lists nothing until its screen appears
        #expect(states.settings.current == .defaults)
    }
}
