import Foundation
import MainternanceDomain

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

/// Which copy of a duplicate group is kept; the rest are marked as removable. Nothing is moved here.
///
/// Exactly one file is kept whatever the rule, so the removable files are never all the copies.
struct DuplicateSelection: Equatable, Sendable {
    let kept: FileItem?
    let removable: [FileItem]

    /// Ties break by shorter path, then alphabetical path, so the result is deterministic (also when two copies
    /// have identical dates).
    init(group: [FileItem], rule: KeepRule) {
        let ordered = group.sorted { lhs, rhs in
            switch rule {
            case .newest where lhs.modified != rhs.modified: return lhs.modified > rhs.modified
            case .oldest where lhs.modified != rhs.modified: return lhs.modified < rhs.modified
            default: break
            }
            if lhs.id.count != rhs.id.count {
                return lhs.id.count < rhs.id.count
            }
            return lhs.id < rhs.id
        }
        kept = ordered.first
        removable = Array(ordered.dropFirst())
    }

    func isKept(_ file: FileItem) -> Bool {
        kept?.id == file.id
    }
}
