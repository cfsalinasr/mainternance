import Foundation
import MainternanceDomain
import Observation

/// The real Cleanup screen: measures the fixed Cleanup folders through `CleanupScanning`, lets the owner choose
/// entries, and after a review and an explicit confirm moves them to the Trash through `CleanupMoving`.
///
/// Every entry is selected after a measuring. Only entries that really moved leave the list and count as freed; one
/// that could not be moved stays listed with its reason. Only the newest measuring is shown, whatever order
/// measurings finish in; nothing is measured while moving, and nothing moves while measuring.
@MainActor
@Observable
public final class CleanupViewState {
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
    /// Why an entry that is still listed could not be moved last time.
    private(set) var failures: [String: String] = [:]
    private var measuresInFlight = 0

    /// Told about every measurement shown, and the updated one after a move (Home's estimate).
    @ObservationIgnored public var onMeasurement: (@MainActor (CleanupMeasurement) -> Void)?
    @ObservationIgnored private let scanner: any CleanupScanning
    @ObservationIgnored private let mover: any CleanupMoving
    @ObservationIgnored private var generation = 0

    public init(scanner: any CleanupScanning, mover: any CleanupMoving) {
        self.scanner = scanner
        self.mover = mover
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

    /// Measure again is offered while nothing is measuring or moving.
    var canMeasure: Bool {
        !isMeasuring && !isMoving
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

    var resultText: String? {
        lastOutcome.map(CleanupText.result)
    }

    var failureLines: [String] {
        lastOutcome?.failed.map(CleanupText.failure) ?? []
    }

    private func category(_ kind: CleanupKind) -> CleanupCategory? {
        categories.first { $0.kind == kind }
    }

    // MARK: - Actions

    /// The screen appeared: measures, unless a measuring or a move is already running.
    public func appear() async {
        guard canMeasure else { return }
        await measure()
    }

    /// Measures again; ignored while moving. Every entry is selected afterwards.
    public func measure() async {
        guard !isMoving else { return }
        message = nil
        generation += 1
        let mine = generation
        measuresInFlight += 1
        defer { measuresInFlight -= 1 }
        let read = await scanner.measure()
        guard mine == generation else { return }
        measurement = read
        selected = Set(read.categories.flatMap(\.entries).map(\.id))
        failures = [:]
        onMeasurement?(read)
    }

    /// Selects every entry of the category, or clears them all when all were selected. Ignored while moving.
    func toggleCategory(_ kind: CleanupKind) {
        guard !isMoving, let entries = category(kind)?.entries else { return }
        let ids = Set(entries.map(\.id))
        if isSelected(category: kind) {
            selected.subtract(ids)
        } else {
            selected.formUnion(ids)
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
    }

    func review() {
        guard canReview else { return }
        isReviewing = true
    }

    func cancelReview() {
        isReviewing = false
    }

    /// Moves the selected entries to the Trash; only from an open review with something selected.
    func confirm() async {
        let chosen = selectedEntries
        guard isReviewing, !isMoving, !isMeasuring, !chosen.isEmpty else { return }
        isReviewing = false
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
        measurement = updated
        onMeasurement?(updated)
    }
}
