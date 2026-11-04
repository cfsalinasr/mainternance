import Darwin
import Foundation
@testable import MainternanceData
import MainternanceDomain
import Synchronization
import Testing

/// A temp "home" and a temp "Applications" folder. Never the real `~/Library`, `/Applications` or Trash.
struct UninstallerFixture {
    let temp: TempDirectory

    init() throws {
        temp = try TempDirectory()
        for folder in [applications, library] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
    }

    var home: URL {
        temp.url.appendingPathComponent("home", isDirectory: true)
    }

    var library: URL {
        home.appendingPathComponent("Library", isDirectory: true)
    }

    var applications: URL {
        temp.url.appendingPathComponent("Applications", isDirectory: true)
    }

    var lister: AppLister {
        AppLister(applicationFolders: [applications], ownBundlePath: nil)
    }

    var finder: LeftoverFinder {
        LeftoverFinder(home: home)
    }

    /// A `.app` folder with a real `Info.plist` holding `plist`; nil `plist` writes none. Returns its path.
    @discardableResult
    func app(
        _ folderName: String, in parent: URL? = nil, plist: [String: Any]? = [:], bytes: Int = 0
    ) throws -> URL {
        let url = (parent ?? applications).appendingPathComponent(folderName, isDirectory: true)
        let contents = url.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        if let plist {
            try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
                .write(to: contents.appendingPathComponent("Info.plist"))
        }
        if bytes > 0 {
            try payload(bytes).write(to: contents.appendingPathComponent("payload.bin"))
        }
        return url
    }

    func installed(
        _ folderName: String = "Example.app", id: String? = "com.example.app", name: String? = nil
    ) async throws -> InstalledApp {
        var plist: [String: Any] = [:]
        if let id {
            plist["CFBundleIdentifier"] = id
        }
        if let name {
            plist["CFBundleName"] = name
        }
        let url = try app(folderName, plist: plist)
        guard let found = await listed().first(where: { $0.id == url.path }) else {
            throw FixtureError.notListed
        }
        return found
    }

    func listed() async -> [InstalledApp] {
        await lister.listApps()
    }

    /// A folder or file inside `~/Library/<path>`; with `bytes`, a file of that size at the last component.
    @discardableResult
    func library(_ path: String, bytes: Int? = nil) throws -> URL {
        let url = library.appendingPathComponent(path)
        if let bytes {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try payload(bytes).write(to: url)
        } else {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        return url
    }

    func payload(_ bytes: Int) -> Data {
        Data((0 ..< bytes).map { UInt8(truncatingIfNeeded: $0 % 251 + 1) })
    }

    @discardableResult
    func link(_ url: URL, to destination: String) throws -> URL {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(atPath: url.path, withDestinationPath: destination)
        return url
    }
}

enum FixtureError: Error {
    case notListed
}

/// A fake Trash for the Uninstaller: each item is moved into `folder` under a numbered name (an app's leftovers often
/// share a name, such as `Caches/<id>` and `Logs/<id>`). Every call is recorded in order, refused ones too. Never the
/// real Trash.
final class NumberedTrash: Sendable {
    struct Refused: Error {}

    struct Move: Sendable, Equatable {
        let source: URL
        let destination: URL
    }

    let folder: URL
    private let refuses: @Sendable (URL) -> Bool
    private let state = Mutex<(calls: [URL], moves: [Move])>(([], []))

    init(folder: URL, refuses: @escaping @Sendable (URL) -> Bool = { _ in false }) {
        self.folder = folder
        self.refuses = refuses
    }

    /// Every URL the mover asked to move, in order, refused or not.
    var calls: [URL] {
        state.withLock { $0.calls }
    }

    /// The moves that really happened.
    var moves: [Move] {
        state.withLock { $0.moves }
    }

    func trash(_ url: URL) throws {
        try state.withLock { current in
            current.calls.append(url)
            guard !refuses(url) else { throw Refused() }
            let manager = FileManager.default
            try manager.createDirectory(at: folder, withIntermediateDirectories: true)
            let destination = folder.appendingPathComponent("\(current.moves.count)-\(url.lastPathComponent)")
            try manager.moveItem(at: url, to: destination)
            current.moves.append(Move(source: url, destination: destination))
        }
    }
}

extension UninstallerFixture {
    typealias PathCheck = @Sendable (String) -> Bool

    func trash(refuses: @escaping @Sendable (URL) -> Bool = { _ in false }) -> NumberedTrash {
        NumberedTrash(folder: temp.url.appendingPathComponent("trash", isDirectory: true), refuses: refuses)
    }

    /// A mover over the temp Applications folder and temp home only, with the fake Trash `trash`.
    func mover(
        _ trash: NumberedTrash, isRunning: @escaping PathCheck = { _ in false },
        isProtected: @escaping PathCheck = { ProtectedPaths.isProtected($0) },
        volume: @escaping @Sendable (String, ItemStat) -> Int32 = { $1.device }
    ) -> AppMover {
        AppMover(
            home: home, applicationFolders: [applications], isRunning: isRunning,
            trash: { try trash.trash($0) }, isProtected: isProtected, volume: volume
        )
    }

    /// The app's details as the finder measures them (its leftovers included).
    func details(_ app: InstalledApp) async -> AppDetails {
        await finder.details(for: app)
    }

    /// The path the mover really moves: the parent with every link resolved (a temp folder under `/var` is reached
    /// through `/private`), plus the name.
    func real(_ path: String) -> String {
        let parent = (path as NSString).deletingLastPathComponent
        let resolved = CleanupRules.resolve(parent) ?? parent
        return (resolved as NSString).appendingPathComponent((path as NSString).lastPathComponent)
    }

    func exists(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0
    }

    // MARK: Refusal test helpers

    func listedApp(_ name: String = "Example.app") async throws -> InstalledApp {
        let url = try app(name, plist: ["CFBundleIdentifier": "com.example.app"])
        return try #require(await listed().first { $0.id == url.path })
    }

    func identity(_ path: String) -> CleanupEntry.Identity? {
        if case let .found(info) = ItemStat.read(path) {
            return info.identity
        }
        return nil
    }

    func moveApp(
        _ app: InstalledApp, _ trash: NumberedTrash, using custom: AppMover? = nil
    ) async -> UninstallOutcome {
        let leftover = Leftover(
            path: library.appendingPathComponent("Caches/com.example.app").path, location: "Caches",
            match: .identifier, bytes: 1, isLowerBound: false, type: .directory
        )
        return await (custom ?? mover(trash)).moveToTrash(
            app: app, appBytes: 1, leftovers: [leftover], includeApp: true
        )
    }

    func moveLeftovers(
        _ leftovers: [Leftover], _ trash: NumberedTrash, using custom: AppMover? = nil
    ) async throws -> UninstallOutcome {
        let app = try await listedApp()
        return await (custom ?? mover(trash)).moveToTrash(
            app: app, appBytes: 1, leftovers: leftovers, includeApp: false
        )
    }

    func leftover(_ path: String) -> Leftover {
        let full = library.appendingPathComponent(path).path
        var type = CleanupEntry.ItemType.directory
        var found: CleanupEntry.Identity?
        if case let .found(info) = ItemStat.read(full) {
            type = info.type
            found = info.identity
        }
        return Leftover(
            path: full, location: "Caches", match: .identifier, bytes: 7, isLowerBound: false, type: type,
            identity: found
        )
    }
}
