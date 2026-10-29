import Foundation
import Observation

enum FilesSegment: String, CaseIterable, Identifiable, Sendable {
    case search, duplicates, large

    var id: String {
        rawValue
    }

    var title: String {
        switch self {
        case .search: "Search"
        case .duplicates: "Duplicates"
        case .large: "Large files"
        }
    }
}

@MainActor
@Observable
public final class FilesViewState {
    var segment: FilesSegment = .search
    var criteria = FileSearchCriteria()
    var keepRule: KeepRule = .newest
    /// Ids of the treemap nodes drilled into, outermost first.
    private(set) var drillPath: [String] = []

    let files: [SampleFile]
    let duplicates: [DuplicateGroup]
    let largest: [SampleFile]
    let treemap: TreemapNode
    private let now: @Sendable () -> Date

    public convenience init() {
        self.init(files: FilesSampleData.files)
    }

    init(
        files: [SampleFile] = FilesSampleData.files,
        duplicates: [DuplicateGroup] = FilesSampleData.duplicates,
        largest: [SampleFile] = FilesSampleData.largest,
        treemap: TreemapNode = FilesSampleData.treemap,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.files = files
        self.duplicates = duplicates
        self.largest = largest
        self.treemap = treemap
        self.now = now
    }

    var results: [SampleFile] {
        FileSearch.filter(files, criteria: criteria, now: now())
    }

    /// The chain from the root to the currently shown node.
    var breadcrumb: [TreemapNode] {
        var chain = [treemap]
        for id in drillPath {
            guard let next = chain.last?.children.first(where: { $0.id == id }) else { break }
            chain.append(next)
        }
        return chain
    }

    var currentNode: TreemapNode {
        breadcrumb.last ?? treemap
    }

    func drillInto(_ id: String) {
        guard let child = currentNode.children.first(where: { $0.id == id }), !child.children.isEmpty else { return }
        drillPath = Array(drillPath.prefix(breadcrumb.count - 1)) + [id]
    }

    func goUp() {
        guard !drillPath.isEmpty else { return }
        drillPath.removeLast()
    }

    func jump(toDepth depth: Int) {
        drillPath = Array(drillPath.prefix(max(depth, 0)))
    }
}
