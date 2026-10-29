import Observation

@MainActor
@Observable
public final class StartupViewState {
    private(set) var items: [StartupItem]

    public convenience init() {
        self.init(items: SampleLists.startupItems)
    }

    init(items: [StartupItem]) {
        self.items = items
    }

    func items(of kind: StartupKind) -> [StartupItem] {
        items.filter { $0.kind == kind }
    }

    var newCount: Int {
        items.count(where: \.isNew)
    }

    /// Sample state only; unknown ids are ignored.
    func toggle(_ id: String) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].isEnabled.toggle()
    }
}
