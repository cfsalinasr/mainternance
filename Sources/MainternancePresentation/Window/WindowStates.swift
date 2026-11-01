/// The per-screen view states, owned above the views so they survive view recreation.
@MainActor
public final class WindowStates {
    let files: FilesViewState
    let scanner: ScannerViewModel
    let cleanup: CleanupViewState
    let startup: StartupViewState
    let uninstaller: UninstallerViewState
    let settings: SettingsViewState

    public init(scanner: ScannerViewModel) {
        files = FilesViewState()
        self.scanner = scanner
        cleanup = CleanupViewState()
        startup = StartupViewState()
        uninstaller = UninstallerViewState()
        settings = SettingsViewState()
    }
}
