import Foundation
import MainternanceDomain

/// Walks the home folder once for the large-files list and the disk tree.
///
/// The list keeps only the biggest plain files (a bounded heap, never every file); the tree keeps at most
/// `maxChildren` children per folder plus one `Other` node, so memory stays bounded by the number of folders, not
/// files. Packages count once in the tree and never appear in the list. The walk runs at utility priority and
/// stops when the consuming task is cancelled.
struct LargeFileScanner: DiskScanning {
    /// 50 MB, as Finder counts (decimal).
    static let standardThreshold: Int64 = 50_000_000
    static let standardLimit = 200
    static let maxChildren = 40
    static let standardProgressEvery = 500

    let walker: FileWalker
    let threshold: Int64
    let limit: Int
    let progressEvery: Int
    /// Told the result of every walk, including one whose consumer has gone (tests watch cancellation with it).
    let ended: @Sendable (DiskScanResult) -> Void

    init(
        walker: FileWalker, threshold: Int64 = LargeFileScanner.standardThreshold,
        limit: Int = LargeFileScanner.standardLimit, progressEvery: Int = LargeFileScanner.standardProgressEvery,
        ended: @escaping @Sendable (DiskScanResult) -> Void = { _ in }
    ) {
        self.walker = walker
        self.threshold = threshold
        self.limit = max(limit, 0)
        self.progressEvery = max(progressEvery, 1)
        self.ended = ended
    }

    func scan() -> AsyncStream<DiskScanUpdate> {
        // Only the newest updates are buffered: a slow consumer may miss progress, never the final result.
        AsyncStream(bufferingPolicy: .bufferingNewest(16)) { continuation in
            let task = Task.detached(priority: .utility) { [self] in
                let result = run(
                    shouldStop: { Task.isCancelled },
                    progress: { continuation.yield(.progress(scannedFiles: $0)) }
                )
                ended(result)
                continuation.yield(.finished(result))
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// One walk, synchronously. `progress` is told the number of items seen every `progressEvery` items.
    func run(shouldStop: () -> Bool, progress: (Int) -> Void) -> DiskScanResult {
        var largest = LargestFiles(limit: limit)
        let tree = DiskTreeBuilder(root: walker.root, maxChildren: Self.maxChildren)
        var scanned = 0
        var unreadable = 0
        var stopped = false
        walker.walk(
            onFile: { file in
                scanned += 1
                tree.add(file)
                if !file.isPackageRoot, file.bytes >= threshold {
                    largest.insert(FileItem(
                        path: file.path, bytes: file.bytes, modified: file.stat.modified, identity: file.stat.identity
                    ))
                }
                if scanned.isMultiple(of: progressEvery) {
                    progress(scanned)
                }
            },
            onFolderUnreadable: { unreadable += 1 },
            shouldStop: {
                if !stopped, shouldStop() {
                    stopped = true
                }
                return stopped
            }
        )
        return DiskScanResult(
            largest: largest.sorted(), tree: tree.build(), unreadableFolders: unreadable, wasCancelled: stopped
        )
    }
}

/// The `limit` largest files seen, in a min-heap: the smallest kept is replaced when a bigger one arrives.
struct LargestFiles {
    let limit: Int
    private var heap: [FileItem] = []

    init(limit: Int) {
        self.limit = limit
    }

    /// Largest first; equal sizes by path, so the order is stable.
    static func comesFirst(_ lhs: FileItem, _ rhs: FileItem) -> Bool {
        lhs.bytes == rhs.bytes ? lhs.id < rhs.id : lhs.bytes > rhs.bytes
    }

    mutating func insert(_ item: FileItem) {
        guard limit > 0 else { return }
        if heap.count < limit {
            heap.append(item)
            siftUp(heap.count - 1)
        } else if Self.comesFirst(item, heap[0]) {
            heap[0] = item
            siftDown(0)
        }
    }

    func sorted() -> [FileItem] {
        heap.sorted(by: Self.comesFirst)
    }

    /// The heap's top is the item that would be listed last.
    private func below(_ lhs: Int, _ rhs: Int) -> Bool {
        Self.comesFirst(heap[rhs], heap[lhs])
    }

    private mutating func siftUp(_ start: Int) {
        var index = start
        while index > 0 {
            let parent = (index - 1) / 2
            guard below(index, parent) else { return }
            heap.swapAt(index, parent)
            index = parent
        }
    }

    private mutating func siftDown(_ start: Int) {
        var index = start
        while true {
            var smallest = index
            for candidate in [2 * index + 1, 2 * index + 2] where candidate < heap.count && below(candidate, smallest) {
                smallest = candidate
            }
            guard smallest != index else { return }
            heap.swapAt(index, smallest)
            index = smallest
        }
    }
}

/// Builds the disk tree from the walked items, which must arrive depth first (as `FileWalker` reports them: a
/// folder's own items, then each subfolder's whole subtree in turn).
///
/// Only the folders on the path being walked are open. A folder is collapsed into its finished node (its biggest
/// children plus one `Other` node) as soon as the walk moves past it, and an open folder never holds more than
/// twice `maxChildren` entries (the smallest are summed into `Other`), so memory is bounded by the depth of the
/// walk, not the number of files.
final class DiskTreeBuilder {
    /// A file, package or finished subfolder, as small as possible: no full path until its node is made.
    private struct Entry {
        let name: String
        let bytes: Int64
        let isPackage: Bool
        let node: DiskNode?
    }

    private final class Folder {
        let path: String
        let name: String
        var entries: [Entry] = []
        var trimmedBytes: Int64 = 0
        var trimmedCount = 0

        init(path: String, name: String) {
            self.path = path
            self.name = name
        }
    }

    private let maxChildren: Int
    /// The root first, then each folder down to the one being walked.
    private var open: [Folder]
    private var held = 0
    /// The most entries ever held at once across the open folders (tests pin the memory bound with it).
    private(set) var peakHeldEntries = 0

    init(root path: String, maxChildren: Int) {
        open = [Folder(path: path, name: (path as NSString).lastPathComponent)]
        self.maxChildren = max(maxChildren, 1)
    }

    func add(_ file: WalkedFile) {
        let parent = (file.path as NSString).deletingLastPathComponent
        guard enter(parent), let folder = open.last else { return }
        append(
            Entry(
                name: (file.path as NSString).lastPathComponent, bytes: file.bytes, isPackage: file.isPackageRoot,
                node: nil
            ),
            to: folder
        )
    }

    /// The finished tree: every folder still open is collapsed, deepest first.
    func build() -> DiskNode {
        while open.count > 1 {
            closeLast()
        }
        return node(for: open[0])
    }

    /// Collapses the open folders the walk has left, then opens the folders down to `parent`. False when `parent`
    /// is not below the root.
    private func enter(_ parent: String) -> Bool {
        guard Self.isInside(parent, open[0].path) else { return false }
        while open.count > 1, let last = open.last, !Self.isInside(parent, last.path) {
            closeLast()
        }
        guard let current = open.last, parent != current.path else { return true }
        var path = current.path
        for component in parent.dropFirst(path.count + 1).split(separator: "/") {
            let name = String(component)
            path = (path as NSString).appendingPathComponent(name)
            open.append(Folder(path: path, name: name))
        }
        return true
    }

    private static func isInside(_ path: String, _ folder: String) -> Bool {
        path == folder || path.hasPrefix(folder.hasSuffix("/") ? folder : folder + "/")
    }

    private func closeLast() {
        let folder = open.removeLast()
        held -= folder.entries.count
        let finished = node(for: folder)
        if let parent = open.last {
            append(Entry(name: folder.name, bytes: finished.bytes, isPackage: false, node: finished), to: parent)
        }
    }

    private func append(_ entry: Entry, to folder: Folder) {
        folder.entries.append(entry)
        held += 1
        // Only the biggest entries can stay; the rest are summed now so a folder of many items stays small.
        if folder.entries.count > 2 * maxChildren {
            folder.entries.sort(by: Self.comesFirst)
            let rest = folder.entries[maxChildren...]
            folder.trimmedBytes = CleanupMath.sum([folder.trimmedBytes] + rest.map(\.bytes))
            folder.trimmedCount += rest.count
            held -= rest.count
            folder.entries.removeSubrange(maxChildren...)
        }
        peakHeldEntries = max(peakHeldEntries, held)
    }

    private func node(for folder: Folder) -> DiskNode {
        let sorted = folder.entries.sorted(by: Self.comesFirst)
        var children = sorted.prefix(maxChildren).map { entry in
            entry.node ?? DiskNode(
                id: (folder.path as NSString).appendingPathComponent(entry.name), name: entry.name,
                bytes: entry.bytes, isOther: false, isPackage: entry.isPackage, children: []
            )
        }
        let rest = sorted.dropFirst(maxChildren)
        if !rest.isEmpty || folder.trimmedCount > 0 {
            children.append(DiskNode(
                id: folder.path + "\u{0}other", name: "Other",
                bytes: CleanupMath.sum([folder.trimmedBytes] + rest.map(\.bytes)), isOther: true, isPackage: false,
                children: []
            ))
        }
        return DiskNode(
            id: folder.path, name: folder.name, bytes: CleanupMath.sum(children.map(\.bytes)), isOther: false,
            isPackage: false, children: children
        )
    }

    /// Largest first; equal sizes by name, so the order is stable.
    private static func comesFirst(_ lhs: Entry, _ rhs: Entry) -> Bool {
        lhs.bytes == rhs.bytes ? lhs.name < rhs.name : lhs.bytes > rhs.bytes
    }
}
