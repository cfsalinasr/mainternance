import MainternanceData
import MainternanceDomain
import MainternancePresentation

@MainActor
enum CompositionRoot {
    /// The provider is created once here and reused for every poll: the CPU reader keeps its baseline in it.
    static func makeOverviewViewModel() -> OverviewViewModel {
        let load = LoadOverview(
            snapshots: LiveSystemSnapshotProvider(),
            scans: NoScannerStatusProvider(),
            actions: NoSuggestedActionsProvider()
        )
        return OverviewViewModel(load: load)
    }
}
