import Foundation
import MainternanceDomain

/// Lists the launchd jobs, adds launchd's on/off state and what is new since the owner's last review.
///
/// `readsState` false (Home's counter) skips `launchctl` (every state stays unknown) and never writes the baseline.
/// With `invalidates`, every listing marks Home's cached count as stale (the screen just read everything again).
struct StartupLister: StartupListing {
    let reader: LaunchItemReader
    let states: LaunchctlStateReader
    let review: StartupReviewStore
    let readsState: Bool
    var invalidates: CachedStartupListing?

    func list() async -> StartupSnapshot {
        defer { invalidates?.invalidate() }
        let found = reader.read()
        var items = found.items
        if readsState {
            async let user = states.states(.user)
            async let system = states.states(.system)
            let (userStates, systemStates) = await (user, system)
            for index in items.indices {
                // Agents (the owner's and those for all users) run in the login session; daemons in the system.
                let known = items[index].kind == .systemDaemon ? systemStates : userStates
                guard let known, let label = items[index].label else { continue }
                // No launchd entry: the plist's own Disabled key decides (true is off; false or absent is on).
                items[index].isEnabled = known[label] ?? !items[index].disabledInFile
            }
        }
        var snapshot = StartupSnapshot(unreadableFolders: found.unreadableFolders)
        switch review.baseline(establishing: readsState ? items : nil) {
        case let .reviewed(seen):
            for index in items.indices where !items[index].isReviewed(in: seen) {
                items[index].isNew = true
            }
            snapshot.baselineEstablished = true
            snapshot.newCount = items.count(where: \.isNew)
            snapshot.reviewReadOnly = readsState && !review.canWrite()
        case let .missing(saved):
            snapshot.reviewReadOnly = readsState && !saved
        case .unreadable:
            snapshot.reviewUnreadable = true
        }
        var seenLabels: [String: Int] = [:]
        for label in items.compactMap(\.label) {
            seenLabels[label, default: 0] += 1
        }
        snapshot.duplicateLabels = Set(seenLabels.filter { $0.value > 1 }.keys)
        snapshot.items = items
        return snapshot
    }
}

/// Saves the Startup screen's review. What was known before for a launchd folder the snapshot could not open is
/// kept, and Home's cached count is marked stale.
struct StartupReviewer: StartupReviewing {
    let review: StartupReviewStore
    let sources: [LaunchItemSource]
    let cache: CachedStartupListing

    func markReviewed(_ snapshot: StartupSnapshot) async -> Bool {
        defer { cache.invalidate() }
        let blind = Set(sources.filter { snapshot.unreadableFolders.contains($0.folder.path) }.map(\.kind))
        return review.markReviewed(snapshot.items, keeping: blind)
    }
}

/// The startup pieces for the whole app, sharing one review store.
public struct StartupServices: Sendable {
    /// How old Home's count of new items may get before the files are read again.
    static let counterMinimumAge: TimeInterval = 60

    /// The Startup screen's lister: reads launchd's state and creates the review baseline on its first listing.
    public let lister: any StartupListing
    public let controller: any StartupControlling
    public let reviewer: any StartupReviewing
    /// Home's count of new items: reads the files and the baseline only; never runs `launchctl`, never writes.
    /// Home polls every few seconds, so the answer is reused for up to `counterMinimumAge`, and read again as soon
    /// as the Startup screen lists or marks as reviewed.
    public let newItemCounter: any StartupListing

    /// `directory` holds `startup-review.json` (the app's Application Support folder).
    public init(
        runner: any ProcessRunning = SystemProcessRunner(),
        directory: URL,
        uid: uid_t = getuid(),
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) {
        self.init(
            runner: runner, directory: directory, uid: uid, sources: LaunchItemReader.standardSources(home: home),
            now: Date.init, clock: Date.init, trash: PreferencesStore.moveToTrash,
            isProtected: { ProtectedPaths.isProtected($0) }
        )
    }

    /// Tests pass temp folders, a fake runner, a fake Trash, a fixed `now` (for the saved review) and a `clock`
    /// (for the age of Home's cached count).
    init(
        runner: any ProcessRunning, directory: URL, uid: uid_t, sources: [LaunchItemSource],
        now: @escaping @Sendable () -> Date, clock: @escaping @Sendable () -> Date,
        trash: @escaping @Sendable (URL) throws -> Void, isProtected: @escaping @Sendable (String) -> Bool
    ) {
        let reader = LaunchItemReader(sources: sources)
        let states = LaunchctlStateReader(runner: runner, uid: uid)
        let review = StartupReviewStore(directory: directory, now: now, trash: trash, isProtected: isProtected)
        let counter = CachedStartupListing(
            base: StartupLister(reader: reader, states: states, review: review, readsState: false),
            minimumAge: Self.counterMinimumAge, now: clock
        )
        lister = StartupLister(reader: reader, states: states, review: review, readsState: true, invalidates: counter)
        newItemCounter = counter
        controller = LaunchctlController(runner: runner, uid: uid)
        reviewer = StartupReviewer(review: review, sources: sources, cache: counter)
    }
}
