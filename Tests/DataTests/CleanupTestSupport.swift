import Foundation
@testable import MainternanceData
import MainternanceDomain

/// A temp "home" with the Cleanup folders, a fake Trash folder and a fixed clock. Never the real `~/Library`,
/// `~/Downloads` or Trash: the services are built over the temp home with a Trash closure that moves items into
/// `trashFolder`.
struct CleanupFixture {
    static let now = Date(timeIntervalSince1970: 1_800_000_000)
    static let day: TimeInterval = 86400

    let temp: TempDirectory
    let trash: FakeTrash

    init(developer: Bool = true) throws {
        temp = try TempDirectory()
        trash = FakeTrash(folder: temp.url.appendingPathComponent("trash", isDirectory: true))
        var folders = [caches, logs, downloads]
        if developer {
            folders.append(derivedData)
        }
        for folder in folders {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
    }

    var home: URL {
        temp.url.appendingPathComponent("home", isDirectory: true)
    }

    var caches: URL {
        home.appendingPathComponent("Library/Caches", isDirectory: true)
    }

    var logs: URL {
        home.appendingPathComponent("Library/Logs", isDirectory: true)
    }

    var downloads: URL {
        home.appendingPathComponent("Downloads", isDirectory: true)
    }

    var derivedData: URL {
        home.appendingPathComponent("Library/Developer/Xcode/DerivedData", isDirectory: true)
    }

    var trashFolder: URL {
        trash.folder
    }

    var roots: [CleanupRoot] {
        CleanupRoots.standard(home: home)
    }

    var rules: CleanupRules {
        CleanupRules(roots: roots, now: { Self.now })
    }

    var measurer: CleanupMeasurer {
        CleanupMeasurer(rules: rules)
    }

    typealias PathGuard = @Sendable (String) -> Bool

    func mover(isProtected: @escaping PathGuard = { ProtectedPaths.isProtected($0) }) -> CleanupMover {
        let fake = trash
        return CleanupMover(rules: rules, trash: { try fake.trash($0) }, isProtected: isProtected)
    }

    var services: CleanupServices {
        let fake = trash
        return CleanupServices(home: home, now: { Self.now }, trash: { try fake.trash($0) })
    }

    /// Writes `bytes` bytes (not all zero, so nothing is sparse) and returns the file's URL.
    @discardableResult
    func file(_ path: String, in folder: URL, bytes: Int = 1000, age: TimeInterval? = nil) throws -> URL {
        let url = folder.appendingPathComponent(path)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data((0 ..< bytes).map { UInt8(truncatingIfNeeded: $0 % 251 + 1) }).write(to: url)
        if let age {
            try FileManager.default.setAttributes(
                [.modificationDate: Self.now.addingTimeInterval(-age)], ofItemAtPath: url.path
            )
        }
        return url
    }

    @discardableResult
    func folder(_ path: String, in parent: URL) throws -> URL {
        let url = parent.appendingPathComponent(path, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @discardableResult
    func link(_ name: String, in folder: URL, to destination: String) throws -> URL {
        let url = folder.appendingPathComponent(name)
        try FileManager.default.createSymbolicLink(atPath: url.path, withDestinationPath: destination)
        return url
    }

    func exists(_ url: URL) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: url.path)) != nil
    }

    func trashed(_ name: String) -> Bool {
        exists(trashFolder.appendingPathComponent(name))
    }
}

/// Allocated sizes are rounded up to whole blocks, so a measured size is checked against a range, never exactly.
func isAbout(_ measured: Int64, _ written: Int) -> Bool {
    measured >= Int64(written) && measured < Int64(written) + 1_048_576
}
