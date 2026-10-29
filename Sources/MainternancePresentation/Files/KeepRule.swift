import Foundation

enum KeepRule: String, CaseIterable, Identifiable, Sendable {
    case newest, oldest, shortestPath

    var id: String {
        rawValue
    }

    var title: String {
        switch self {
        case .newest: "Newest"
        case .oldest: "Oldest"
        case .shortestPath: "Shortest path"
        }
    }
}

/// Which file of a duplicate group is kept; the rest are marked as removable. Nothing is deleted here.
struct DuplicateSelection: Equatable, Sendable {
    let kept: SampleFile?
    let removable: [SampleFile]

    /// Ties break by shorter path, then alphabetical path, so the result is deterministic.
    init(group: [SampleFile], rule: KeepRule) {
        let ordered = group.sorted { lhs, rhs in
            switch rule {
            case .newest where lhs.modified != rhs.modified: return lhs.modified > rhs.modified
            case .oldest where lhs.modified != rhs.modified: return lhs.modified < rhs.modified
            default: break
            }
            if lhs.path.count != rhs.path.count {
                return lhs.path.count < rhs.path.count
            }
            return lhs.path < rhs.path
        }
        kept = ordered.first
        removable = Array(ordered.dropFirst())
    }

    func isKept(_ file: SampleFile) -> Bool {
        kept?.id == file.id
    }

    var reclaimableBytes: Int64 {
        removable.reduce(0) { $0 + max($1.size, 0) }
    }
}
