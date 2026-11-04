import Foundation
@testable import MainternanceData
import MainternanceDomain

// Helpers for the file trasher tests. Everything happens inside a `FilesFixture` temp folder; the Trash is a
// `NumberedTrash` that moves items into that temp folder, never the real Trash.

extension FilesFixture {
    /// The fake Trash: a folder beside the temp home.
    func trash(refuses: @escaping @Sendable (URL) -> Bool = { _ in false }) -> NumberedTrash {
        NumberedTrash(folder: temp.url.appendingPathComponent("trash", isDirectory: true), refuses: refuses)
    }

    func trasher(
        _ trash: NumberedTrash, isProtected: @escaping @Sendable (String) -> Bool = { _ in false },
        volume: @escaping @Sendable (String, ItemStat) -> Int32 = { $1.device }
    ) -> FileTrasher {
        FileTrasher(home: home, trash: { try trash.trash($0) }, isProtected: isProtected, volume: volume)
    }

    /// The item as a scan would have recorded it: `lstat`, allocated bytes, identity and modified date.
    func item(_ url: URL) throws -> FileItem {
        guard case let .found(info) = ItemStat.read(url.path) else { throw FixtureError.notListed }
        return FileItem(path: url.path, bytes: info.allocated, modified: info.modified, identity: info.identity)
    }

    func exists(_ url: URL) -> Bool {
        if case .found = ItemStat.read(url.path) {
            return true
        }
        return false
    }

    /// A folder beside the temp home, outside it.
    func outside(_ name: String, bytes: Int = 1000) throws -> URL {
        let url = temp.url.appendingPathComponent("outside", isDirectory: true).appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try pattern(bytes).write(to: url)
        return URL(fileURLWithPath: FilesFixture.resolved(url.path))
    }

    /// A group of identical copies at `relatives`, as the duplicate finder would report it.
    func group(_ relatives: [String], bytes: Int = 4096) throws -> DuplicateGroup {
        let items = try relatives.map { try item(write($0, pattern(bytes))) }
        return DuplicateGroup(id: "\(bytes)-test", bytesEach: items.map(\.bytes).min() ?? 0, files: items)
    }

    func setModified(_ url: URL, _ seconds: TimeInterval) throws {
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: seconds)], ofItemAtPath: url.path
        )
    }

    /// Adds bytes to the end of the file, in place (same item, new size).
    func grow(_ url: URL, by count: Int = 8192) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: pattern(count, seed: 3))
    }

    /// Puts a different file at the same path (a new item, same name and size).
    func replace(_ url: URL) throws {
        let aside = url.deletingLastPathComponent().appendingPathComponent("replacement.tmp")
        try Data(contentsOf: url).write(to: aside)
        try FileManager.default.removeItem(at: url)
        try FileManager.default.moveItem(at: aside, to: url)
    }
}

extension FileItem {
    /// The same path, with another recorded size or identity (what a stale or forged scan result would hold).
    func with(bytes: Int64? = nil, modified: Date? = nil, identity: CleanupEntry.Identity?? = .none) -> FileItem {
        FileItem(
            path: id, bytes: bytes ?? self.bytes, modified: modified ?? self.modified,
            identity: identity ?? self.identity
        )
    }
}
