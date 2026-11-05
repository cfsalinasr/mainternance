import Foundation
import MainternanceDomain
import Observation

/// The real Cleanup screen: measures the fixed Cleanup folders through `CleanupScanning`, lets the owner choose
/// entries, and after a review and an explicit confirm moves them to the Trash through `CleanupMoving`.
///
/// After a measuring every entry is selected except old installers, which move only once the owner ticks them (on
/// every new measuring they start unticked again); an entry the owner unticked stays unticked in every later
/// measuring (also one that was running while they unticked it, and one that runs when they come back). A
/// measuring that finishes after a move clears that move's result card. Only entries that really moved leave the
/// list and count as freed; one that could not be moved stays listed with its reason. Only the newest measuring is
/// shown, whatever order measurings finish in, and a measuring cancelled (the screen was left) is dropped: the
/// previous list stays and Home is not told. Nothing is measured while moving or while the review is open, nothing
/// moves while measuring, and a list older than `maximumAge` is not cleaned.
@MainActor
@Observable
public final class CleanupViewState {
    /// A list older than this is out of date for cleaning: measure again first.
    static let maximumAge: TimeInterval = 300

    /// Nil until the first measuring finished.
    public private(set) var measurement: CleanupMeasurement?
    public private(set) var isMoving = false
    /// True while the review sheet is open.
    public private(set) var isReviewing = false
    /// What the last move to the Trash really did.
    public private(set) var lastOutcome: CleanupOutcome?
    /// A short line about the last action, when it needs words.
    public private(set) var message: String?
    private(set) var selected: Set<String> = []
    /// The entries the owner unticked, by id; kept across measurings, so a new list never re-ticks them.
    private var unticked: Set<String> = []
    /// Why an entry that is still listed could not be moved last time.
    private(set) var failures: [String: String] = [:]
    private var measuresInFlight = 0

    /// Told about every measurement shown, and the updated one after a move (Home's estimate).
    @ObservationIgnored public var onMeasurement: (@MainActor (CleanupMeasurement) -> Void)?
    @ObservationIgnored private let scanner: any CleanupScanning
    @ObservationIgnored private let mover: any CleanupMoving
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private var generation = 0
    /// When the list on screen was measured (by this clock).
    @ObservationIgnored private var measuredAt = Date.distantPast

    public init(
        scanner: any CleanupScanning, mover: any CleanupMoving, now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.scanner = scanner
        self.mover = mover
        self.now = now
    }

    // MARK: - Derived state

    public var isMeasuring: Bool {
        measuresInFlight > 0
    }

    /// The spinner: only while nothing has been measured yet (a later measuring keeps the list on screen).
    var showsMeasuring: Bool {
        measurement == nil && isMeasuring
    }

    var categories: [CleanupCategory] {
        measurement?.categories ?? []
    }

    /// Measured, and not a single entry in any folder.
    var showsNothingFound: Bool {
        measurement != nil && categories.allSatisfy(\.entries.isEmpty)
    }

    var notes: [String] {
        measurement?.unreadable.map(CleanupText.unreadable) ?? []
    }

    /// The selected entries in list order.
    var selectedEntries: [CleanupEntry] {
        categories.flatMap(\.entries).filter { selected.contains($0.id) }
    }

    var selectedBytes: Int64 {
        CleanupMath.sum(selectedEntries.map(\.bytes))
    }

    var selectedText: String {
        CleanupText.selected(selectedBytes, lowerBound: selectedEntries.contains(where: \.isLowerBound))
    }

    func selectedEntries(in kind: CleanupKind) -> [CleanupEntry] {
        category(kind)?.entries.filter { selected.contains($0.id) } ?? []
    }

    /// Something is selected and nothing is measuring or moving.
    var canReview: Bool {
        !selectedEntries.isEmpty && !isMeasuring && !isMoving
    }

    /// Checkboxes work except while moving.
    var canToggle: Bool {
        !isMoving
    }

    /// A category's checkbox: only with entries to tick, and not while moving.
    func canToggle(_ category: CleanupCategory) -> Bool {
        canToggle && !category.entries.isEmpty
    }

    /// The review sheet's sections: categories with something in them.
    var reviewCategories: [CleanupCategory] {
        categories.filter { !$0.entries.isEmpty }
    }

    /// Measure again is offered while nothing is measuring or moving and the review is closed.
    var canMeasure: Bool {
        !isMeasuring && !isMoving && !isReviewing
    }

    /// A category's size, or that nothing was found in it.
    func sizeText(_ category: CleanupCategory) -> String {
        category.entries.isEmpty ? CleanupText.emptyCategory : CleanupText.size(category)
    }

    /// "2 of 5 selected" under a category with entries.
    func selectionText(_ category: CleanupCategory) -> String? {
        guard !category.entries.isEmpty else { return nil }
        return "\(selectedEntries(in: category.kind).count) of \(category.entries.count) selected"
    }

    func isSelected(entry id: String) -> Bool {
        selected.contains(id)
    }

    /// True when the category has entries and all of them are selected.
    func isSelected(category kind: CleanupKind) -> Bool {
        guard let entries = category(kind)?.entries, !entries.isEmpty else { return false }
        return entries.allSatisfy { selected.contains($0.id) }
    }

    func failureReason(_ id: String) -> String? {
        failures[id]
    }

    /// True when there is something to say about the last action: a result, or a refusal such as 'out of date'.
    var showsResultCard: Bool {
        lastOutcome != nil || message != nil
    }

    var resultText: String? {
        lastOutcome.flatMap(CleanupText.result)
    }

    var failureLines: [String] {
        lastOutcome?.failed.map(CleanupText.failure) ?? []
    }

    private func category(_ kind: CleanupKind) -> CleanupCategory? {
        categories.first { $0.kind == kind }
    }

    // MARK: - Actions

    /// The screen appeared: measures, unless a measuring or a move is already running or the review is open.
    public func appear() async {
        guard canMeasure else { return }
        await measure()
    }

    /// Measures again; ignored while moving or reviewing (a new list must never re-tick what the owner unticked in
    /// the review). Afterwards every entry is selected except old installers and what the owner unticked. A finished
    /// measuring clears the last move's result. A measuring whose task was cancelled (the screen was left) only has
    /// lower-bound sizes: it is dropped and the previous list stays.
    public func measure() async {
        guard !isMoving, !isReviewing else { return }
        message = nil
        generation += 1
        let mine = generation
        measuresInFlight += 1
        defer { measuresInFlight -= 1 }
        let read = await scanner.measure()
        guard mine == generation, !Task.isCancelled else { return }
        measurement = read
        measuredAt = now()
        selected = Set(read.categories.flatMap { category in
            category.kind.isSelectedByDefault ? category.entries.map(\.id).filter { !unticked.contains($0) } : []
        })
        failures = [:]
        lastOutcome = nil
        onMeasurement?(read)
    }

    /// Selects every entry of the category, or clears them all when all were selected. Ignored while moving.
    func toggleCategory(_ kind: CleanupKind) {
        guard !isMoving, let entries = category(kind)?.entries else { return }
        let ids = Set(entries.map(\.id))
        let tick = !isSelected(category: kind)
        if tick {
            selected.formUnion(ids)
        } else {
            selected.subtract(ids)
        }
        if tick {
            unticked.subtract(ids)
        } else {
            unticked.formUnion(ids)
        }
    }

    /// Ignored for an id that is not listed, and while moving.
    func toggleEntry(_ id: String) {
        guard !isMoving, categories.contains(where: { $0.entries.contains { $0.id == id } }) else { return }
        if selected.contains(id) {
            selected.remove(id)
        } else {
            selected.insert(id)
        }
        if selected.contains(id) {
            unticked.remove(id)
        } else {
            unticked.insert(id)
        }
    }

    func review() {
        guard canReview else { return }
        isReviewing = true
    }

    func cancelReview() {
        isReviewing = false
    }

    /// Moves the selected entries to the Trash; only from an open review with something selected, and only while the
    /// list is at most `maximumAge` old (a clock that went backwards counts as out of date).
    func confirm() async {
        let chosen = selectedEntries
        guard isReviewing, !isMoving, !isMeasuring, !chosen.isEmpty else { return }
        isReviewing = false
        let age = now().timeIntervalSince(measuredAt)
        guard age >= 0, age <= Self.maximumAge else {
            message = CleanupText.outOfDate
            return
        }
        isMoving = true
        message = nil
        defer { isMoving = false }
        let outcome = await mover.moveToTrash(chosen)
        apply(outcome)
    }

    private func apply(_ outcome: CleanupOutcome) {
        lastOutcome = outcome
        failures = Dictionary(outcome.failed.map { ($0.entry.id, $0.reason) }, uniquingKeysWith: { first, _ in first })
        guard !outcome.moved.isEmpty, var updated = measurement else {
            message = CleanupText.nothingMoved
            return
        }
        // A measuring started before this move must not bring the moved entries back.
        generation += 1
        let moved = Set(outcome.moved.map(\.id))
        for index in updated.categories.indices {
            updated.categories[index].entries.removeAll { moved.contains($0.id) }
        }
        selected.subtract(moved)
        // Something found later at a moved path is a new item: it gets its category's default.
        unticked.subtract(moved)
        measurement = updated
        onMeasurement?(updated)
    }
}
