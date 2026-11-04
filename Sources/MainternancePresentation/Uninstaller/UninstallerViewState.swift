import Foundation
import MainternanceDomain
import Observation

/// The real Uninstaller screen: lists the installed apps, measures the selected app and finds its leftovers, and
/// after a review and an explicit confirm moves what is ticked to the Trash.
///
/// Selecting ticks the app and the leftovers found by identifier; name-only and launch-agent leftovers start unticked.
/// Only the newest selection is shown, whatever order lookups finish in. Nothing is selected, listed or moved while
/// another of those is running or the review is open, and nothing moves without `review()` first. Only what really
/// moved leaves the screen; a leftover that could not move stays listed with its reason.
@MainActor
@Observable
public final class UninstallerViewState {
    public private(set) var apps: [InstalledApp] = []
    /// The selected app with its size and leftovers; nil while loading or when nothing is selected.
    public private(set) var details: AppDetails?
    public private(set) var selectedID: String?
    public private(set) var isListing = false
    public private(set) var isLoadingDetails = false
    public private(set) var isMoving = false
    /// True while the review sheet is open.
    public private(set) var isReviewing = false
    /// What the last move to the Trash really did.
    public private(set) var lastOutcome: UninstallOutcome?
    public var searchText = ""
    private(set) var includesApp = false
    private var ticked: Set<String> = []
    /// Why a leftover that is still listed could not be moved last time.
    private(set) var failures: [String: String] = [:]
    /// The app and its measured state the last outcome was about, for the result card.
    private var lastApp: (name: String, isLowerBound: Bool)?

    @ObservationIgnored private let lister: any AppListing
    @ObservationIgnored private let finder: any LeftoverFinding
    @ObservationIgnored private let mover: any AppUninstalling
    @ObservationIgnored private var generation = 0

    public init(lister: any AppListing, finder: any LeftoverFinding, mover: any AppUninstalling) {
        self.lister = lister
        self.finder = finder
        self.mover = mover
    }

    // MARK: - Derived state

    var visibleApps: [InstalledApp] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return apps }
        return apps.filter { $0.displayName.localizedCaseInsensitiveContains(query) }
    }

    /// The ticked leftovers in list order.
    var selectedLeftovers: [Leftover] {
        details?.leftovers.filter { ticked.contains($0.id) } ?? []
    }

    var selectedBytes: Int64 {
        CleanupMath.sum([includesApp ? details?.appBytes ?? 0 : 0] + selectedLeftovers.map(\.bytes))
    }

    var selectedText: String {
        let partial = (includesApp && details?.appIsLowerBound == true) || selectedLeftovers
            .contains(where: \.isLowerBound)
        return UninstallerText.selected(selectedBytes, lowerBound: partial)
    }

    private var isBusy: Bool {
        isListing || isLoadingDetails || isMoving
    }

    /// The app or a leftover is ticked and nothing is loading or moving.
    var canReview: Bool {
        details != nil && (includesApp || !selectedLeftovers.isEmpty) && !isBusy
    }

    /// Selecting and ticking work except while moving or reviewing.
    var canChange: Bool {
        !isMoving && !isReviewing
    }

    /// The app is open, as far as anyone knows before trying: the screen says "Quit it first" up front.
    var showsQuitNote: Bool {
        details != nil
    }

    func isSelected(leftover id: String) -> Bool {
        ticked.contains(id)
    }

    func failureReason(_ id: String) -> String? {
        failures[id]
    }

    func leftovers(_ match: LeftoverMatch) -> [Leftover] {
        details?.leftovers.filter { $0.match == match } ?? []
    }

    var showsResultCard: Bool {
        lastOutcome != nil
    }

    var resultText: String? {
        lastOutcome.map { UninstallerText.result($0, lowerBound: lastApp?.isLowerBound == true) }
    }

    var failureLines: [String] {
        lastOutcome.map { UninstallerText.failureLines($0, appName: lastApp?.name ?? "") } ?? []
    }

    // MARK: - Actions

    /// The screen appeared: lists the apps, unless a listing or a move is running or the review is open.
    public func appear() async {
        guard !isListing, !isMoving, !isReviewing else { return }
        isListing = true
        defer { isListing = false }
        let listed = await lister.listApps()
        guard !Task.isCancelled else { return }
        apps = listed
        if let selectedID, !listed.contains(where: { $0.id == selectedID }) {
            clearSelection()
        }
    }

    /// Selects an app and loads its leftovers. An id that is not listed (or nil) clears the selection. Ignored while
    /// moving or reviewing. A lookup that was overtaken by a newer one, or cancelled, is dropped.
    func select(_ id: String?) async {
        guard canChange else { return }
        generation += 1
        let mine = generation
        guard let id, let app = apps.first(where: { $0.id == id }) else {
            clearSelection()
            return
        }
        selectedID = id
        details = nil
        includesApp = false
        ticked = []
        failures = [:]
        isLoadingDetails = true
        let found = await finder.details(for: app)
        guard mine == generation else { return }
        isLoadingDetails = false
        guard !Task.isCancelled else {
            clearSelection()
            return
        }
        details = found
        includesApp = true
        ticked = Set(found.leftovers.filter(\.match.isSelectedByDefault).map(\.id))
    }

    func toggleApp() {
        guard canChange, details != nil else { return }
        includesApp.toggle()
    }

    /// Ignored for an id that is not listed, and while moving or reviewing.
    func toggleLeftover(_ id: String) {
        guard canChange, details?.leftovers.contains(where: { $0.id == id }) == true else { return }
        if ticked.contains(id) {
            ticked.remove(id)
        } else {
            ticked.insert(id)
        }
    }

    func review() {
        guard canReview, !isReviewing else { return }
        isReviewing = true
    }

    func cancelReview() {
        isReviewing = false
    }

    /// Moves the ticked app and leftovers to the Trash; only from an open review with something ticked.
    func confirm() async {
        guard isReviewing, canReview, let current = details else { return }
        let chosen = selectedLeftovers
        let includeApp = includesApp
        isReviewing = false
        isMoving = true
        defer { isMoving = false }
        let outcome = await mover.moveToTrash(
            app: current.app, appBytes: current.appBytes, leftovers: chosen, includeApp: includeApp
        )
        apply(outcome, to: current)
    }

    private func clearSelection() {
        isLoadingDetails = false
        selectedID = nil
        details = nil
        includesApp = false
        ticked = []
        failures = [:]
    }

    private func apply(_ outcome: UninstallOutcome, to moved: AppDetails) {
        lastOutcome = outcome
        lastApp = (moved.app.displayName, moved.appIsLowerBound)
        failures = Dictionary(
            outcome.failedLeftovers.map { ($0.leftover.id, $0.reason) }, uniquingKeysWith: { first, _ in first }
        )
        if outcome.appMoved {
            apps.removeAll { $0.id == moved.app.id }
            clearSelection()
            failures = [:]
            return
        }
        let gone = Set(outcome.movedLeftovers.map(\.id))
        guard !gone.isEmpty, let current = details else { return }
        details = AppDetails(
            app: current.app, appBytes: current.appBytes, appIsLowerBound: current.appIsLowerBound,
            leftovers: current.leftovers.filter { !gone.contains($0.id) }
        )
        ticked.subtract(gone)
    }
}
