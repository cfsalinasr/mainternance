import Foundation
import MainternanceDomain
@testable import MainternancePresentation
import Synchronization

/// Stands in for the Data layer's lister, finder and mover: scripted answers, recorded moves. Nothing touches disk.
final class FakeUninstaller: AppListing, LeftoverFinding, AppUninstalling {
    struct Move: Equatable {
        let appID: String
        let appBytes: Int64
        let leftoverIDs: [String]
        let includeApp: Bool
    }

    struct State {
        var apps: [InstalledApp]
        var details: [String: AppDetails]
        var lists = 0
        var moves: [Move] = []
        /// Leftover ids that fail to move, with their reason.
        var failing: [String: String] = [:]
        /// When set, the app is refused with this reason and its leftovers are skipped.
        var appRefusal: String?
    }

    let state: Mutex<State>

    init(apps: [InstalledApp] = UninstallerRig.apps, details: [AppDetails] = UninstallerRig.allDetails) {
        state = Mutex(State(apps: apps, details: Dictionary(uniqueKeysWithValues: details.map { ($0.app.id, $0) })))
    }

    func configure(_ body: (inout State) -> Void) {
        state.withLock { body(&$0) }
    }

    func listApps() async -> [InstalledApp] {
        state.withLock { current in
            current.lists += 1
            return current.apps
        }
    }

    func details(for app: InstalledApp) async -> AppDetails {
        state
            .withLock { $0.details[app.id] ?? AppDetails(app: app, appBytes: 0, appIsLowerBound: false, leftovers: []) }
    }

    func moveToTrash(
        app: InstalledApp, appBytes: Int64, leftovers: [Leftover], includeApp: Bool
    ) async -> UninstallOutcome {
        state.withLock { current in
            current.moves.append(
                Move(appID: app.id, appBytes: appBytes, leftoverIDs: leftovers.map(\.id), includeApp: includeApp)
            )
            if includeApp, let reason = current.appRefusal {
                return UninstallOutcome(
                    appMoved: false, appFailure: reason, appBytes: appBytes, movedLeftovers: [], failedLeftovers: [],
                    skipped: leftovers
                )
            }
            let failed = leftovers.compactMap { item in
                current.failing[item.id].map { LeftoverFailure(leftover: item, reason: $0) }
            }
            return UninstallOutcome(
                appMoved: includeApp, appFailure: nil, appBytes: appBytes,
                movedLeftovers: leftovers.filter { current.failing[$0.id] == nil }, failedLeftovers: failed,
                skipped: []
            )
        }
    }

    var lists: Int {
        state.withLock { $0.lists }
    }

    var moves: [Move] {
        state.withLock { $0.moves }
    }
}

/// A finder whose answers wait until the test releases them.
final class GatedFinder: LeftoverFinding {
    let gate = Gate<AppDetails>()

    func details(for _: InstalledApp) async -> AppDetails {
        await gate.wait()
    }
}

/// A mover whose move waits until the test releases it.
final class GatedUninstaller: AppUninstalling {
    let gate = Gate<UninstallOutcome>()

    func moveToTrash(
        app _: InstalledApp, appBytes _: Int64, leftovers _: [Leftover], includeApp _: Bool
    ) async -> UninstallOutcome {
        await gate.wait()
    }
}

/// A lister whose answers wait until the test releases them.
final class GatedLister: AppListing {
    let gate = Gate<[InstalledApp]>()

    func listApps() async -> [InstalledApp] {
        await gate.wait()
    }
}

@MainActor
struct UninstallerRig {
    let fake: FakeUninstaller
    let state: UninstallerViewState

    init(_ fake: FakeUninstaller = FakeUninstaller()) {
        self.fake = fake
        state = UninstallerViewState(lister: fake, finder: fake, mover: fake)
    }

    nonisolated static let megabyte: Int64 = 1_000_000
    nonisolated static let library = "/Users/me/Library"

    nonisolated static let photo = InstalledApp(
        path: "/Applications/Photo Studio.app", name: "Photo Studio", bundleID: "com.example.photo", version: "2.1"
    )
    nonisolated static let notes = InstalledApp(
        path: "/Applications/Notes Plus.app", name: "Notes Plus", bundleID: "com.example.notes", version: nil
    )
    nonisolated static let apps = [notes, photo]

    nonisolated static func leftover(
        _ name: String, _ megabytes: Int64, _ match: LeftoverMatch, folder: String = "Caches", lowerBound: Bool = false
    ) -> Leftover {
        Leftover(
            path: "\(library)/\(folder)/\(name)", location: folder, match: match, bytes: megabytes * megabyte,
            isLowerBound: lowerBound, type: .directory
        )
    }

    nonisolated static let photoCache = leftover("com.example.photo", 200, .identifier)
    nonisolated static let photoSupport = leftover(
        "com.example.photo", 800, .identifier, folder: "Application Support"
    )
    nonisolated static let photoByName = leftover("Photo Studio", 30, .nameOnly, folder: "Application Support")
    nonisolated static let photoAgent = leftover(
        "com.example.photo.helper.plist", 1, .launchAgent, folder: "LaunchAgents"
    )

    nonisolated static let photoDetails = AppDetails(
        app: photo, appBytes: 500 * megabyte, appIsLowerBound: false,
        leftovers: [photoSupport, photoCache, photoByName, photoAgent]
    )
    nonisolated static let notesDetails = AppDetails(
        app: notes, appBytes: 40 * megabyte, appIsLowerBound: false,
        leftovers: [leftover("com.example.notes", 5, .identifier)]
    )
    nonisolated static let allDetails = [photoDetails, notesDetails]
}
