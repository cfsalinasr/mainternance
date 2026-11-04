/// The per-screen view states, owned above the views so they survive view recreation.
@MainActor
public final class WindowStates {
    let files: FilesViewState
    let scanner: ScannerViewModel
    let cleanup: CleanupViewState
    let startup: StartupViewState
    let uninstaller: UninstallerViewState
    let settings: SettingsViewState

    public init(
        scanner: ScannerViewModel, settings: SettingsViewState, startup: StartupViewState, cleanup: CleanupViewState,
        uninstaller: UninstallerViewState, files: FilesViewState
    ) {
        self.files = files
        self.scanner = scanner
        self.cleanup = cleanup
        self.startup = startup
        self.uninstaller = uninstaller
        self.settings = settings
    }
}
