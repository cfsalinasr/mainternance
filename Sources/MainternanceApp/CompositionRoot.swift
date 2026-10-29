import MainternanceData
import MainternanceDomain
import MainternancePresentation

@MainActor
enum CompositionRoot {
    static func makeOverviewViewModel() -> OverviewViewModel {
        let load = LoadOverview(
            snapshots: MockSystemSnapshotProvider(),
            scans: MockScanStatusProvider(),
            actions: MockSuggestedActionsProvider()
        )
        return OverviewViewModel(load: load)
    }
}
