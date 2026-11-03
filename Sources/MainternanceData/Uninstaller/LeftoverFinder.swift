import Foundation
import MainternanceDomain

/// Finds what an app left in a fixed set of `~/Library` folders, and measures it.
///
/// Read-only. Each fixed folder's children are listed once and compared with the app's identifier and name by exact
/// text (never "contains"); no path is ever built from the app's name or identifier, only from names listed on disk.
/// A folder that is a link (or sits below a link in `~/Library`) is not read. Each match is read with `lstat` (a link
/// counts as the link itself, never followed) and folders are sized with `CleanupMeasurer.size(of:device:)`.
struct LeftoverFinder: LeftoverFinding {
    let home: URL

    private enum Rule {
        /// `<id>` exactly.
        case exact
        /// `<id>` plus an extension.
        case suffixed(String)
        /// `<id>` exactly, or anything ending `.<id>` (Group Containers carry a team prefix).
        case teamPrefixed
        /// `<id>.plist` or anything starting `<id>.`.
        case launchAgent
    }

    private static let identifierRules: [(folder: String, rule: Rule)] = [
        ("Application Support", .exact), ("Caches", .exact), ("Containers", .exact),
        ("Group Containers", .teamPrefixed), ("Preferences", .suffixed(".plist")),
        ("Saved Application State", .suffixed(".savedState")), ("HTTPStorages", .exact), ("WebKit", .exact),
        ("Cookies", .suffixed(".binarycookies")), ("Logs", .exact), ("LaunchAgents", .launchAgent)
    ]
    private static let nameFolders = ["Application Support", "Logs", "Caches"]
    static let minimumNameLength = 4

    func details(for app: InstalledApp) async -> AppDetails {
        let (appBytes, appComplete) = Self.measureApp(app)
        let leftovers = candidates(for: app).compactMap(Self.measure)
        let ordered = leftovers.sorted { $0.bytes == $1.bytes ? $0.id < $1.id : $0.bytes > $1.bytes }
        return AppDetails(
            app: app, appBytes: appBytes, appIsLowerBound: !appComplete && !Self.isGone(app), leftovers: ordered
        )
    }

    // MARK: App size

    private static func isGone(_ app: InstalledApp) -> Bool {
        if case .missing = ItemStat.read(app.id) {
            return true
        }
        return false
    }

    private static func measureApp(_ app: InstalledApp) -> (Int64, Bool) {
        switch ItemStat.read(app.id) {
        case let .found(info) where info.type == .directory:
            CleanupMeasurer.size(of: app.id, device: info.device)
        case let .found(info):
            (info.allocated, true)
        case .missing:
            (0, true)
        case .unreadable:
            (0, false)
        }
    }

    // MARK: Finding

    private struct Candidate {
        let path: String
        let location: String
        let match: LeftoverMatch
    }

    private func candidates(for app: InstalledApp) -> [Candidate] {
        let library = home.appendingPathComponent("Library", isDirectory: true)
        guard Self.isRealFolder(library.path) else { return [] }
        let name = app.name.count >= Self.minimumNameLength ? app.name.lowercased() : nil
        var found: [Candidate] = []
        for (folder, rule) in Self.identifierRules {
            let path = library.appendingPathComponent(folder, isDirectory: true).path
            guard Self.isRealFolder(path),
                  let children = try? FileManager.default.contentsOfDirectory(atPath: path) else { continue }
            for child in children.sorted() {
                guard let match = Self.match(child, folder: folder, rule: rule, id: app.bundleID, name: name)
                else { continue }
                found.append(Candidate(
                    path: (path as NSString).appendingPathComponent(child), location: folder, match: match
                ))
            }
        }
        return found
    }

    private static func match(
        _ child: String, folder: String, rule: Rule, id: String?, name: String?
    ) -> LeftoverMatch? {
        guard !child.isEmpty, child != ".", child != "..", !child.contains("/") else { return nil }
        if let id {
            switch rule {
            case .exact where child == id, .teamPrefixed where child == id || child.hasSuffix("." + id):
                return .identifier
            case let .suffixed(ending) where child == id + ending:
                return .identifier
            case .launchAgent where child == id + ".plist" || child.hasPrefix(id + "."):
                return .launchAgent
            default:
                break
            }
        }
        if let name, nameFolders.contains(folder), child.lowercased() == name {
            return .nameOnly
        }
        return nil
    }

    private static func isRealFolder(_ path: String) -> Bool {
        if case let .found(info) = ItemStat.read(path) {
            return info.type == .directory
        }
        return false
    }

    private static func measure(_ candidate: Candidate) -> Leftover? {
        guard case let .found(info) = ItemStat.read(candidate.path) else { return nil }
        var bytes = info.allocated
        var complete = true
        if info.type == .directory {
            (bytes, complete) = CleanupMeasurer.size(of: candidate.path, device: info.device)
        }
        return Leftover(
            path: candidate.path, location: candidate.location, match: candidate.match, bytes: bytes,
            isLowerBound: !complete, type: info.type, identity: info.identity
        )
    }
}
