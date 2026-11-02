import Foundation
import MainternanceDomain
@testable import MainternancePresentation
import Synchronization

/// Stands in for the Data layer's lister, controller and reviewer at once, so a toggle or a review shows up in the
/// next listing the way the real pieces do. Real Domain types throughout.
final class FakeStartup: StartupListing, StartupControlling, StartupReviewing {
    struct State {
        var snapshot = StartupSnapshot()
        var controlError: StartupError?
        var toggles: [(id: String, enabled: Bool)] = []
        var reviewed: [[String]] = []
        var lists = 0
    }

    let state: Mutex<State>

    init(_ snapshot: StartupSnapshot = StartupSnapshot()) {
        state = Mutex(State(snapshot: snapshot))
    }

    func configure(_ body: (inout State) -> Void) {
        state.withLock { body(&$0) }
    }

    func list() async -> StartupSnapshot {
        state.withLock { current in
            current.lists += 1
            return current.snapshot
        }
    }

    func setEnabled(_ item: StartupItem, _ enabled: Bool) async throws {
        try state.withLock { current in
            current.toggles.append((item.id, enabled))
            if let error = current.controlError {
                throw error
            }
            for index in current.snapshot.items.indices where current.snapshot.items[index].id == item.id {
                current.snapshot.items[index].isEnabled = enabled
            }
        }
    }

    func markReviewed(_ labels: [String]) async {
        state.withLock { current in
            current.reviewed.append(labels)
            let keys = Set(labels)
            for index in current.snapshot.items.indices where keys.contains(current.snapshot.items[index].reviewKey) {
                current.snapshot.items[index].isNew = false
            }
            current.snapshot.baselineEstablished = true
            current.snapshot.newCount = current.snapshot.items.count(where: \.isNew)
        }
    }

    var lists: Int {
        state.withLock { $0.lists }
    }

    var toggles: [(id: String, enabled: Bool)] {
        state.withLock { $0.toggles }
    }

    var reviewed: [[String]] {
        state.withLock { $0.reviewed }
    }
}

/// A Startup screen state over a `FakeStartup`, recording what Reveal in Finder was asked to show.
@MainActor
struct StartupRig {
    let fake: FakeStartup
    let revealed = Recorded<String>()
    let state: StartupViewState

    init(_ snapshot: StartupSnapshot = StartupRig.sample) {
        let fake = FakeStartup(snapshot)
        let revealed = revealed
        self.fake = fake
        state = StartupViewState(
            lister: fake, controller: fake, reviewer: fake, reveal: { revealed.add($0) }
        )
    }

    static func item(
        _ label: String?, kind: StartupKind = .userAgent, enabled: Bool? = true, isNew: Bool = false,
        problem: String? = nil, file: String? = nil
    ) -> StartupItem {
        let folder = switch kind {
        case .userAgent: "/Users/me/Library/LaunchAgents"
        case .systemAgent: "/Library/LaunchAgents"
        case .systemDaemon: "/Library/LaunchDaemons"
        }
        var item = StartupItem(
            kind: kind, plistPath: "\(folder)/\(file ?? label ?? "unnamed").plist", label: label,
            program: label.map { "/Applications/\($0).app/Contents/MacOS/helper" }, readProblem: problem
        )
        item.isEnabled = enabled
        item.isNew = isNew
        return item
    }

    /// One of each kind, one of them new, after the baseline existed.
    static var sample: StartupSnapshot {
        StartupSnapshot(
            items: [
                item("com.example.updater"), item("com.example.sync", isNew: true),
                item("com.vendor.agent", kind: .systemAgent), item("com.vendor.daemon", kind: .systemDaemon)
            ],
            baselineEstablished: true, newCount: 1
        )
    }
}
