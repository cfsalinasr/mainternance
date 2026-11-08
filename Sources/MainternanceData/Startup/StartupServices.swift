import Foundation
import MainternanceDomain

/// Lists the launchd jobs, adds launchd's on/off state and what is new or changed since the owner's last review.
///
/// `readsState` false (Home's counter) skips `launchctl` (every state stays unknown) and never creates the baseline;
/// the only write it makes is the one-time upgrade of keys saved before programs were part of the review.
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
            // A review that cannot be saved could never be cleared, so it marks nothing (Home's count included);
            // the baseline was read, so the count is a known zero, not unknown.
            let readOnly = !review.canWrite()
            if !readOnly {
                mark(&items, against: seen)
            }
            snapshot.baselineEstablished = true
            snapshot.newCount = items.count(where: \.needsReview)
            snapshot.reviewReadOnly = readOnly // Home must then say it could not check, not "nothing new"
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

    /// Marks new and changed items. Items matched only by a key saved before programs were part of the review
    /// count as reviewed this once, and their current keys are saved in place of the old ones at once, by this
    /// listing or Home's counter, whichever reads first: from then on a change of their program is flagged
    /// everywhere, Home's count included.
    private func mark(_ items: inout [StartupItem], against baseline: StartupReviewBaseline) {
        var upgraded: [StartupItem] = []
        for (index, match) in zip(items.indices, baseline.matches(items)) {
            switch match {
            case .reviewed: break
            case .reviewedBeforeUpgrade: upgraded.append(items[index])
            case .changed: items[index].isChanged = true
            case .new: items[index].isNew = true
            }
        }
        if !upgraded.isEmpty {
            _ = review.upgrade(upgraded)
        }
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
    /// Home's count of new and changed items: reads the files and the baseline; never runs `launchctl`, and writes
    /// only the one-time upgrade of old review keys (see `StartupLister`).
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
            runner: runner, uid: uid, sources: LaunchItemReader.standardSources(home: home), clock: Date.init,
            review: StartupReviewStore(directory: directory)
        )
    }

    /// Tests pass temp folders, a fake runner, a `clock` (for the age of Home's cached count) and a review store
    /// built over a temp folder with a fake Trash and a fixed `now` (for the saved review).
    init(
        runner: any ProcessRunning, uid: uid_t, sources: [LaunchItemSource],
        clock: @escaping @Sendable () -> Date, review: StartupReviewStore
    ) {
        let reader = LaunchItemReader(sources: sources)
        let states = LaunchctlStateReader(runner: runner, uid: uid)
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
