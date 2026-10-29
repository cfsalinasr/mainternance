import Observation

@MainActor
@Observable
public final class UninstallerViewState {
    let apps: [SampleApp]
    private(set) var selectedID: String?

    public convenience init() {
        self.init(apps: SampleLists.apps)
    }

    init(apps: [SampleApp]) {
        self.apps = apps
        selectedID = apps.first?.id
    }

    var selectedApp: SampleApp? {
        selectedID.flatMap { id in apps.first { $0.id == id } }
    }

    /// An unknown id (or nil) clears the selection.
    func select(_ id: String?) {
        selectedID = id.flatMap { id in apps.contains { $0.id == id } ? id : nil }
    }
}
