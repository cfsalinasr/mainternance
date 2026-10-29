/// The per-screen view states, owned above the views so they survive view recreation.
@MainActor
public final class WindowStates {
    let files: FilesViewState
    let scanner: ScannerViewState
    let cleanup: CleanupViewState
    let startup: StartupViewState
    let uninstaller: UninstallerViewState
    let settings: SettingsViewState

    public init() {
        files = FilesViewState()
        scanner = ScannerViewState()
        cleanup = CleanupViewState()
        startup = StartupViewState()
        uninstaller = UninstallerViewState()
        settings = SettingsViewState()
    }
}
