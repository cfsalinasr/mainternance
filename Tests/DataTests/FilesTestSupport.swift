import Foundation
@testable import MainternanceData
import MainternanceDomain

/// A temp "home" for the file walker and the large-file scanner. Never the real home folder, `~/Library` or the
/// Trash: every walk starts at `home`, a folder inside a fresh temp directory.
struct FilesFixture {
    let temp: TempDirectory

    init() throws {
        temp = try TempDirectory()
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    var home: URL {
        temp.url.appendingPathComponent("home", isDirectory: true)
    }

    /// Writes `bytes` non-zero bytes at `path` (relative to the home folder), making its folders.
    @discardableResult
    func file(_ path: String, bytes: Int = 1000) throws -> URL {
        let url = home.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data((0 ..< bytes).map { UInt8(truncatingIfNeeded: $0 % 251 + 1) }).write(to: url)
        return url
    }

    @discardableResult
    func folder(_ path: String) throws -> URL {
        let url = home.appendingPathComponent(path, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @discardableResult
    func link(_ path: String, to destination: String) throws -> URL {
        let url = home.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: url.path, withDestinationPath: destination)
        return url
    }

    func path(_ relative: String) -> String {
        home.appendingPathComponent(relative).path
    }

    func walker(
        isProtected: @escaping @Sendable (String) -> Bool = { _ in false },
        volume: @escaping @Sendable (String, ItemStat) -> Int32 = { $1.device }
    ) -> FileWalker {
        FileWalker(home: home, isProtected: isProtected, volume: volume)
    }

    /// Everything one walk reports, in order.
    func walk(_ walker: FileWalker? = nil, stopAfter limit: Int? = nil) -> WalkRecord {
        var record = WalkRecord()
        (walker ?? self.walker()).walk(
            onFile: { record.files.append($0) },
            onFolderUnreadable: { record.unreadable += 1 },
            shouldStop: {
                record.stopChecks += 1
                return limit.map { record.files.count >= $0 } ?? false
            }
        )
        return record
    }

    func scanner(
        threshold: Int64 = 20000, limit: Int = 200, progressEvery: Int = 1000,
        ended: @escaping @Sendable (DiskScanResult) -> Void = { _ in }
    ) -> LargeFileScanner {
        LargeFileScanner(
            walker: walker(), threshold: threshold, limit: limit, progressEvery: progressEvery, ended: ended
        )
    }

    /// Makes `url` unreadable for the length of `body`, then readable again so the temp folder can be removed.
    func unreadable<T>(_ url: URL, _ body: () async throws -> T) async rethrows -> T {
        chmod(url.path, 0)
        defer { chmod(url.path, 0o755) }
        return try await body()
    }
}

struct WalkRecord {
    var files: [WalkedFile] = []
    var unreadable = 0
    var stopChecks = 0

    var paths: [String] {
        files.map(\.path)
    }
}

/// Collects every update of one scan until the stream ends.
func collectUpdates(_ stream: AsyncStream<DiskScanUpdate>) async -> [DiskScanUpdate] {
    var updates: [DiskScanUpdate] = []
    for await update in stream {
        updates.append(update)
    }
    return updates
}

/// The finished result in `updates`, if any.
func finishedResult(_ updates: [DiskScanUpdate]) -> DiskScanResult? {
    for update in updates {
        if case let .finished(result) = update {
            return result
        }
    }
    return nil
}

/// The node named `name` among `node`'s children.
func child(_ name: String, of node: DiskNode) -> DiskNode? {
    node.children.first { $0.name == name }
}

/// Thread-safe box for results delivered from the scanner's background task.
final class Received<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [Value] = []

    func add(_ value: Value) {
        lock.withLock { stored.append(value) }
    }

    var values: [Value] {
        lock.withLock { stored }
    }
}
