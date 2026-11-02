import Foundation
import MainternanceDomain
import Observation

/// Every user-visible Startup string, pinned by tests. Plain descriptions of what is registered and by which file;
/// never a "safe" or "suspicious" judgement.
enum StartupText {
    static let title = "Startup"
    static let intro = "Launch agents and daemons start programs when you log in or when the Mac starts."
    static let takesEffect = "Takes effect at your next login."
    static let allUsersNote = "Installed for all users: Mainternance only switches your own agents."
    static let baselineFromToday = "Showing a baseline from today: nothing counts as new yet."
    static let reviewUnreadable =
        "The list of items you already reviewed could not be read, so nothing is marked as new."
    static let reviewNotSaved =
        "Your review could not be saved, so nothing will be marked as new. Mark all as reviewed is off."
    static let reviewSaveFailed = "Could not save your review, so nothing changed."
    static let loginItemsFooter = [
        "Login items you added in System Settings > General > Login Items are managed by macOS",
        "and are not listed here."
    ].joined(separator: " ")
    static let markAllReviewed = "Mark all as reviewed"
    static let empty = "No launch agents or daemons were found."
    static let loading = "Reading the startup items…"
    static let duplicate = "Another file registers the same label."
    static let newBadge = "New"
    static let newBadgeAccessibility = "New since your last review"
    static let reveal = "Reveal in Finder"
    static let noLabel = "No label"
    static let noProgram = "No program listed"

    static func sectionTitle(_ kind: StartupKind) -> String {
        switch kind {
        case .userAgent: "Your agents"
        case .systemAgent: "Agents for all users"
        case .systemDaemon: "System daemons"
        }
    }

    /// launchd's state; nil (it could not be read) is "Unknown", never a guess.
    static func state(_ enabled: Bool?) -> String {
        switch enabled {
        case true?: "On"
        case false?: "Off"
        case nil: "Unknown"
        }
    }

    static func unreadableFolder(_ path: String) -> String {
        "Could not open \(path), so its items are not listed."
    }
}

/// The real Startup screen: the launch agents and daemons on this Mac, read through `StartupListing`.
///
/// Only the owner's own agents can be switched (through `StartupControlling`); a switch takes effect at the next
/// login. A failed switch leaves the shown state as it was and says why. "New" means not present at the last review;
/// the first listing ever only creates that baseline.
@MainActor
@Observable
public final class StartupViewState {
    /// Nil until the first reading finished.
    public private(set) var snapshot: StartupSnapshot?
    /// Items with a switch in progress; their switch is disabled meanwhile.
    public private(set) var busyIDs: Set<String> = []
    /// The result of the last action when it needs words.
    public private(set) var message: String?
    private var loadsInFlight = 0

    @ObservationIgnored private let lister: any StartupListing
    @ObservationIgnored private let controller: any StartupControlling
    @ObservationIgnored private let reviewer: any StartupReviewing
    @ObservationIgnored private let revealInFinder: @MainActor (String) -> Void
    /// Only the latest reading is shown, whatever order readings finish in.
    @ObservationIgnored private var generation = 0

    public init(
        lister: any StartupListing, controller: any StartupControlling, reviewer: any StartupReviewing,
        reveal: @escaping @MainActor (String) -> Void
    ) {
        self.lister = lister
        self.controller = controller
        self.reviewer = reviewer
        revealInFinder = reveal
    }

    // MARK: - Derived state

    var isLoading: Bool {
        loadsInFlight > 0
    }

    /// The spinner: only while nothing has been read yet (a later reading keeps the rows on screen).
    var showsLoading: Bool {
        snapshot == nil && isLoading
    }

    /// The "nothing found" message, only once something was read.
    var showsEmptyState: Bool {
        snapshot?.items.isEmpty == true
    }

    func items(of kind: StartupKind) -> [StartupItem] {
        snapshot?.items.filter { $0.kind == kind } ?? []
    }

    var baselineNote: String? {
        guard let snapshot else { return nil }
        if snapshot.reviewUnreadable {
            return StartupText.reviewUnreadable
        }
        if snapshot.reviewReadOnly {
            return StartupText.reviewNotSaved
        }
        // Only the reading that created the baseline says so; the next one can already show items as New.
        return snapshot.baselineEstablished ? nil : StartupText.baselineFromToday
    }

    var folderNotes: [String] {
        snapshot?.unreadableFolders.map(StartupText.unreadableFolder) ?? []
    }

    /// The lines under the title, each once: the baseline note, the last action's result, unreadable folders.
    var notes: [String] {
        var seen: [String] = []
        for note in [baselineNote, message].compactMap(\.self) + folderNotes where !seen.contains(note) {
            seen.append(note)
        }
        return seen
    }

    /// Only what was read can be marked as reviewed, and only while the review can be read and saved.
    var canMarkReviewed: Bool {
        guard let snapshot else { return false }
        return !snapshot.reviewUnreadable && !snapshot.reviewReadOnly
    }

    /// "label · program" as display text (no bidi, zero-width or control characters), with plain words for what
    /// the file does not say.
    func detail(_ item: StartupItem) -> String {
        "\(item.displayLabel ?? StartupText.noLabel) · \(item.displayProgram ?? StartupText.noProgram)"
    }

    func duplicateNote(_ item: StartupItem) -> String? {
        guard let label = item.label, snapshot?.duplicateLabels.contains(label) == true else { return nil }
        return StartupText.duplicate
    }

    /// The small lines under a row: why it could not be read, a shared label, why it has no switch.
    func rowNotes(_ item: StartupItem) -> [String] {
        [item.readProblem, duplicateNote(item), readOnlyNote(item)].compactMap(\.self)
    }

    /// Shown instead of a switch on items for all users and daemons: read-only here by design.
    func readOnlyNote(_ item: StartupItem) -> String? {
        item.kind == .userAgent ? nil : StartupText.allUsersNote
    }

    /// A switch only for the owner's own agents whose state is known: a switch for an unknown state would claim one.
    func showsSwitch(_ item: StartupItem) -> Bool {
        item.canToggle && item.isEnabled != nil
    }

    func isBusy(_ id: String) -> Bool {
        busyIDs.contains(id)
    }

    // MARK: - Actions

    /// Reads everything again; the last action's message goes.
    public func refresh() async {
        message = nil
        await reload()
    }

    private func reload() async {
        generation += 1
        let mine = generation
        loadsInFlight += 1
        defer { loadsInFlight -= 1 }
        let read = await lister.list()
        guard mine == generation else { return }
        snapshot = read
    }

    /// Switches one of the owner's own agents, then reads launchd's state again. Ignored for an id that is not
    /// listed or already switching; refused with the reason for an item that cannot be switched.
    public func setEnabled(_ id: String, _ enabled: Bool) async {
        guard let item = snapshot?.items.first(where: { $0.id == id }), !busyIDs.contains(id) else { return }
        message = nil
        guard item.canToggle else {
            let reason: StartupError = if item.kind != .userAgent {
                .notAllowed
            } else if item.readProblem != nil {
                .unreadable
            } else {
                .invalidLabel
            }
            message = reason.errorDescription
            return
        }
        busyIDs.insert(id)
        defer { busyIDs.remove(id) }
        do {
            try await controller.setEnabled(item, enabled)
        } catch {
            message = error.localizedDescription
            return
        }
        await reload()
        message = StartupText.takesEffect
    }

    /// Makes everything listed now the baseline, then reads again: no item is new afterwards. A review that could
    /// not be saved says so. Not offered while the review cannot be read or saved (`canMarkReviewed`).
    public func markAllReviewed() async {
        guard canMarkReviewed, let current = snapshot else { return }
        message = nil
        let saved = await reviewer.markReviewed(current)
        await reload()
        if !saved {
            message = StartupText.reviewSaveFailed
        }
    }

    /// Shows the item's property list in Finder; only for items in the snapshot.
    public func reveal(_ id: String) {
        guard let item = snapshot?.items.first(where: { $0.id == id }) else { return }
        revealInFinder(item.plistPath)
    }
}
