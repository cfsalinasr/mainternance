import Foundation
import MainternanceDomain

/// Measures the direct children of the fixed Cleanup folders.
///
/// Read-only. Links are never followed (a link entry counts as the link itself), folders on another volume are not
/// entered (a direct child on another volume is not listed at all), hidden files count. A direct child that holds the
/// running app (`CleanupRules.holdsApp`, for example a build folder in `~/Library/Caches` the app runs from) is not
/// listed: moving it would move Mainternance itself. A subfolder that cannot be
/// read makes its entry's size a lower bound. The walk uses its own list of folders to visit (no recursion, so deep
/// trees cannot exhaust the stack) and checks for cancellation at every item: a cancelled measuring returns at
/// once, with what it has as lower bounds.
struct CleanupMeasurer: CleanupScanning {
    let rules: CleanupRules

    func measure() async -> CleanupMeasurement {
        let now = rules.now()
        var categories: [CleanupCategory] = []
        var unreadable: [CleanupKind] = []
        for root in rules.roots {
            switch CleanupRules.open(root) {
            case .absent:
                continue
            case .unusable:
                unreadable.append(root.kind)
            case let .folder(given, _, identity):
                guard let names = try? FileManager.default.contentsOfDirectory(atPath: given) else {
                    unreadable.append(root.kind)
                    continue
                }
                let entries = names.compactMap { name in
                    entry(name, in: given, root: root, context: (identity.device, now))
                }
                categories.append(CleanupCategory(kind: root.kind, entries: entries.sorted(by: Self.largestFirst)))
            }
        }
        return CleanupMeasurement(categories: categories, measuredAt: now, unreadable: unreadable)
    }

    /// Largest first; equal sizes by name, so the order is stable.
    private static func largestFirst(_ lhs: CleanupEntry, _ rhs: CleanupEntry) -> Bool {
        lhs.bytes == rhs.bytes ? lhs.name < rhs.name : lhs.bytes > rhs.bytes
    }

    private func entry(
        _ name: String, in folder: String, root: CleanupRoot, context: (device: Int32, now: Date)
    ) -> CleanupEntry? {
        let path = (folder as NSString).appendingPathComponent(name)
        // A folder mounted from another volume is neither measured nor offered.
        guard case let .found(info) = ItemStat.read(path), rules.volume(path, info) == context.device,
              rules.accepts(path: path, info, in: root, now: context.now), !rules.holdsApp(path) else { return nil }
        var bytes = info.allocated
        var complete = true
        if info.type == .directory {
            // A folder's own blocks are not counted (Finder does not count them either).
            (bytes, complete) = Self.size(of: path, device: context.device)
        }
        return CleanupEntry(
            path: path, bytes: bytes, isLowerBound: !complete, type: info.type, modified: info.modified,
            identity: info.identity
        )
    }

    /// The allocated bytes below `folder`, and false when anything could not be read or the walk was cancelled.
    static func size(of folder: String, device: Int32) -> (bytes: Int64, complete: Bool) {
        var pending = [folder]
        var total: Int64 = 0
        var complete = true
        while let current = pending.popLast() {
            guard !Task.isCancelled else { return (total, false) }
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: current) else {
                complete = false
                continue
            }
            for name in names {
                guard !Task.isCancelled else { return (total, false) }
                let child = (current as NSString).appendingPathComponent(name)
                switch ItemStat.read(child) {
                case let .found(info) where info.type == .directory:
                    if info.device == device {
                        pending.append(child)
                    }
                case let .found(info):
                    let added = total.addingReportingOverflow(info.allocated)
                    total = added.overflow ? .max : added.partialValue
                case .missing:
                    continue // removed while measuring: nothing to count
                case .unreadable:
                    complete = false
                }
            }
        }
        return (total, complete)
    }
}
