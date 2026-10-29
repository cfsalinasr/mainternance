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
        let schedule = ScanScheduleStore() // One schedule, shared by Settings (edits) and the Scanner (reads).
        files = FilesViewState()
        scanner = ScannerViewState(schedule: schedule)
        cleanup = CleanupViewState()
        startup = StartupViewState()
        uninstaller = UninstallerViewState()
        settings = SettingsViewState(schedule: schedule)
    }
}
