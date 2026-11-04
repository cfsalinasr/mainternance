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
        let tree = DiskTreeBuilder(root: walker.home.path, maxChildren: Self.maxChildren)
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

/// Builds the disk tree from the walked items: folders are created as items below them arrive, and each folder
/// keeps only its biggest items (the rest are summed into `Other`). Built bottom-up, without recursion.
final class DiskTreeBuilder {
    private final class Folder {
        let path: String
        let name: String
        var subfolders: [String: Folder] = [:]
        var leaves: [DiskNode] = []
        var trimmedBytes: Int64 = 0
        var trimmedCount = 0
        var built: DiskNode?

        init(path: String, name: String) {
            self.path = path
            self.name = name
        }
    }

    private let root: Folder
    private let maxChildren: Int

    init(root path: String, maxChildren: Int) {
        root = Folder(path: path, name: (path as NSString).lastPathComponent)
        self.maxChildren = max(maxChildren, 1)
    }

    func add(_ file: WalkedFile) {
        let prefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        guard file.path.hasPrefix(prefix) else { return }
        let components = file.path.dropFirst(prefix.count).split(separator: "/", omittingEmptySubsequences: true)
        guard let leafName = components.last else { return }
        var folder = root
        for component in components.dropLast() {
            let name = String(component)
            if let existing = folder.subfolders[name] {
                folder = existing
            } else {
                let created = Folder(path: (folder.path as NSString).appendingPathComponent(name), name: name)
                folder.subfolders[name] = created
                folder = created
            }
        }
        folder.leaves.append(DiskNode(
            id: file.path, name: String(leafName), bytes: file.bytes, isOther: false, isPackage: file.isPackageRoot,
            children: []
        ))
        // Only the biggest items can stay; the rest are summed now so a folder of many files stays small.
        if folder.leaves.count > 2 * maxChildren {
            folder.leaves.sort(by: Self.comesFirst)
            let rest = folder.leaves[maxChildren...]
            folder.trimmedBytes = CleanupMath.sum([folder.trimmedBytes] + rest.map(\.bytes))
            folder.trimmedCount += rest.count
            folder.leaves.removeSubrange(maxChildren...)
        }
    }

    /// The finished tree, its folders built after everything below them.
    func build() -> DiskNode {
        var order: [Folder] = []
        var pending = [root]
        while let folder = pending.popLast() {
            order.append(folder)
            pending.append(contentsOf: folder.subfolders.values)
        }
        for folder in order.reversed() {
            folder.built = node(for: folder)
            folder.subfolders = [:]
            folder.leaves = []
        }
        return root.built ?? DiskNode(
            id: root.path, name: root.name, bytes: 0, isOther: false, isPackage: false, children: []
        )
    }

    private func node(for folder: Folder) -> DiskNode {
        let all = (folder.subfolders.values.compactMap(\.built) + folder.leaves).sorted(by: Self.comesFirst)
        var children = Array(all.prefix(maxChildren))
        let rest = all.dropFirst(maxChildren)
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
    private static func comesFirst(_ lhs: DiskNode, _ rhs: DiskNode) -> Bool {
        lhs.bytes == rhs.bytes ? lhs.name < rhs.name : lhs.bytes > rhs.bytes
    }
}
