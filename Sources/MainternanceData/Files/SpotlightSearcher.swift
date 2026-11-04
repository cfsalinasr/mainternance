import Foundation
import MainternanceDomain

/// Searches the home folder through Spotlight and keeps only results that are real, plain files the owner would
/// expect to see.
///
/// Spotlight's answer is a list of paths and is treated as untrusted: each path is resolved, must lie inside the
/// resolved home folder (not under `~/Library`, not under or named like a dot-folder), and is re-read with `lstat`
/// (it must exist and be a plain file, not a link or folder). Results are sorted newest first and capped.
struct SpotlightSearcher: FileSearching {
    static let maxResults = 500
    /// How many paths one query asks Spotlight for (results are dropped after, so ask for more than the cap).
    static let fetchLimit = 2000

    let home: URL
    /// Runs the query for a predicate in a folder, returning at most the given number of paths, newest change first.
    let runQuery: @Sendable (NSPredicate, URL, Int) async -> [String]

    init(
        home: URL,
        runQuery: @escaping @Sendable (NSPredicate, URL, Int) async -> [String] = SpotlightSearcher.runSpotlight
    ) {
        self.home = home
        self.runQuery = runQuery
    }

    func search(_ query: FileSearchQuery) async -> FileSearchResult {
        guard let predicate = SpotlightPredicate.make(query) else {
            return FileSearchResult(files: [], isTruncated: false)
        }
        let paths = await runQuery(predicate, home, Self.fetchLimit)
        if Task.isCancelled {
            return FileSearchResult(files: [], isTruncated: false)
        }
        let root = Self.resolved(home.path)
        var seen = Set<String>()
        var files: [FileItem] = []
        for path in paths {
            guard let item = Self.checked(path, root: root), seen.insert(item.id).inserted else { continue }
            files.append(item)
        }
        files.sort { $0.modified != $1.modified ? $0.modified > $1.modified : $0.id < $1.id }
        let truncated = files.count > Self.maxResults || paths.count >= Self.fetchLimit
        return FileSearchResult(files: Array(files.prefix(Self.maxResults)), isTruncated: truncated)
    }

    /// The item for one path Spotlight reported, or nil when it must not be shown.
    private static func checked(_ path: String, root: String) -> FileItem? {
        guard path.hasPrefix("/") else { return nil }
        let name = (path as NSString).lastPathComponent
        guard !name.isEmpty, name != "..", name != "." else { return nil }
        // Resolve the folder, not the file: a link as the last component is kept so `lstat` can refuse it.
        let parent = resolved((path as NSString).deletingLastPathComponent)
        let full = (parent as NSString).appendingPathComponent(name)
        guard full.hasPrefix(root + "/") else { return nil }
        let relative = full.dropFirst(root.count + 1).split(separator: "/", omittingEmptySubsequences: true)
        guard let first = relative.first, first != "Library", !relative.contains(where: { $0.hasPrefix(".") }),
              case let .found(info) = ItemStat.read(full), info.isRegular else { return nil }
        return FileItem(path: full, bytes: info.allocated, modified: info.modified, identity: info.identity)
    }

    private static func resolved(_ path: String) -> String {
        guard let real = realpath(path, nil) else { return path }
        defer { free(real) }
        return String(cString: real)
    }

    /// The real Spotlight query: an `NSMetadataQuery` on the main run loop, scoped to `home`, newest change first.
    /// It waits for `NSMetadataQueryDidFinishGathering`, stops the query, and returns an empty list if the task is
    /// cancelled. Automated tests never call it (they inject a fake `runQuery`, and Spotlight is never queried from
    /// tests); it is exercised only by the manual check listed in docs/STATUS.md.
    @Sendable
    static func runSpotlight(_ predicate: NSPredicate, _ home: URL, _ limit: Int) async -> [String] {
        nonisolated(unsafe) let predicate = predicate
        return await SpotlightRun().run(predicate: predicate, home: home, limit: limit)
    }
}

/// One Spotlight query; lives on the main actor because `NSMetadataQuery` needs the main run loop.
@MainActor
private final class SpotlightRun {
    private let query = NSMetadataQuery()
    private var observer: NSObjectProtocol?
    private var continuation: CheckedContinuation<[String], Never>?

    func run(predicate: NSPredicate, home: URL, limit: Int) async -> [String] {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume(returning: [])
                    return
                }
                self.continuation = continuation
                query.predicate = predicate
                query.searchScopes = [home]
                query.sortDescriptors = [NSSortDescriptor(key: NSMetadataItemFSContentChangeDateKey, ascending: false)]
                observer = NotificationCenter.default.addObserver(
                    forName: .NSMetadataQueryDidFinishGathering, object: query, queue: .main
                ) { _ in
                    MainActor.assumeIsolated { self.finish(limit: limit, cancelled: false) }
                }
                query.start()
            }
        } onCancel: {
            Task { @MainActor in self.finish(limit: limit, cancelled: true) }
        }
    }

    private func finish(limit: Int, cancelled: Bool) {
        guard let continuation else { return }
        self.continuation = nil
        query.disableUpdates()
        query.stop()
        if let observer {
            NotificationCenter.default.removeObserver(observer)
        }
        observer = nil
        var paths: [String] = []
        if !cancelled {
            for index in 0 ..< min(query.resultCount, limit) {
                let item = query.result(at: index) as? NSMetadataItem
                if let path = item?.value(forAttribute: NSMetadataItemPathKey) as? String {
                    paths.append(path)
                }
            }
        }
        continuation.resume(returning: paths)
    }
}
