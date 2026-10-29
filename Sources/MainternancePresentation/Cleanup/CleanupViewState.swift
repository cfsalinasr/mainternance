import Observation

@MainActor
@Observable
public final class CleanupViewState {
    let categories: [CleanupCategory]
    private(set) var selected: Set<String>
    private(set) var cleaned: Set<String> = []
    /// True while the confirmation sheet is open.
    private(set) var isReviewing = false

    public convenience init() {
        self.init(categories: SampleLists.cleanupCategories)
    }

    init(categories: [CleanupCategory]) {
        self.categories = categories
        selected = Set(categories.map(\.id))
    }

    func isSelected(_ id: String) -> Bool {
        selected.contains(id)
    }

    func isCleaned(_ id: String) -> Bool {
        cleaned.contains(id)
    }

    /// Categories that would move, in list order.
    var reviewItems: [CleanupCategory] {
        categories.filter { selected.contains($0.id) && !cleaned.contains($0.id) }
    }

    var selectedBytes: Int64 {
        SampleLists.sum(reviewItems.map(\.bytes))
    }

    var cleanedBytes: Int64 {
        SampleLists.sum(categories.filter { cleaned.contains($0.id) }.map(\.bytes))
    }

    var canReview: Bool {
        !reviewItems.isEmpty
    }

    /// Unknown, already cleaned and mid-review toggles are no-ops.
    func toggle(_ id: String) {
        guard !isReviewing, categories.contains(where: { $0.id == id }), !cleaned.contains(id) else { return }
        if selected.contains(id) {
            selected.remove(id)
        } else {
            selected.insert(id)
        }
    }

    func review() {
        guard canReview else { return }
        isReviewing = true
    }

    func cancelReview() {
        isReviewing = false
    }

    /// Sample state only; nothing is touched on disk.
    func confirmReview() {
        guard isReviewing else { return }
        let moving = Set(reviewItems.map(\.id))
        cleaned.formUnion(moving)
        selected.subtract(moving)
        isReviewing = false
    }
}
