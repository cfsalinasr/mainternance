import Foundation
import MainternanceDomain

/// Lists the launchd jobs, adds launchd's on/off state and what is new since the owner's last review.
///
/// `readsState` false (Home's counter) skips `launchctl` (every state stays unknown) and never writes the baseline.
struct StartupLister: StartupListing {
    let reader: LaunchItemReader
    let states: LaunchctlStateReader
    let review: StartupReviewStore
    let readsState: Bool

    func list() async -> StartupSnapshot {
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
                items[index].isEnabled = known[label] ?? true // no entry: launchd has not switched it off
            }
        }
        let keys = Set(items.map(\.reviewKey))
        var snapshot = StartupSnapshot(unreadableFolders: found.unreadableFolders)
        switch review.baseline(establishing: readsState ? keys : nil) {
        case let .reviewed(seen):
            for index in items.indices where !seen.contains(items[index].reviewKey) {
                items[index].isNew = true
            }
            snapshot.baselineEstablished = true
            snapshot.newCount = items.count(where: \.isNew)
        case .missing:
            break
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

/// The startup pieces for the whole app, sharing one review store.
public struct StartupServices: Sendable {
    /// The Startup screen's lister: reads launchd's state and creates the review baseline on its first listing.
    public let lister: any StartupListing
    public let controller: any StartupControlling
    public let reviewer: any StartupReviewing
    /// Home's count of new items: reads the files and the baseline only; never runs `launchctl`, never writes.
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
            now: Date.init, trash: PreferencesStore.moveToTrash, isProtected: { ProtectedPaths.isProtected($0) }
        )
    }

    /// Tests pass temp folders, a fake runner, a fake Trash and a fixed clock.
    init(
        runner: any ProcessRunning, directory: URL, uid: uid_t, sources: [LaunchItemSource],
        now: @escaping @Sendable () -> Date, trash: @escaping @Sendable (URL) throws -> Void,
        isProtected: @escaping @Sendable (String) -> Bool
    ) {
        let reader = LaunchItemReader(sources: sources)
        let states = LaunchctlStateReader(runner: runner, uid: uid)
        let review = StartupReviewStore(directory: directory, now: now, trash: trash, isProtected: isProtected)
        lister = StartupLister(reader: reader, states: states, review: review, readsState: true)
        newItemCounter = StartupLister(reader: reader, states: states, review: review, readsState: false)
        controller = LaunchctlController(runner: runner, uid: uid)
        reviewer = review
    }
}
