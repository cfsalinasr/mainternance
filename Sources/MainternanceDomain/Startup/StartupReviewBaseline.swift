import Foundation

/// How one startup item stands against the saved review.
public enum StartupReviewMatch: Sendable, Equatable {
    /// Seen at the last review exactly as it is now (label, file and program).
    case reviewed
    /// Matched only by a key saved before programs were part of the review: counts as reviewed this once, and the
    /// baseline is then upgraded to the item's current key, so a later change of its program is flagged.
    case reviewedBeforeUpgrade
    /// The last review saw this label or this file, but with another file, label or program.
    case changed
    /// Neither this label nor this file was present at the last review.
    case new
}

/// The saved review keys, indexed so an item can be told apart as reviewed, changed or new.
public struct StartupReviewBaseline: Sendable, Equatable {
    /// v2: the fingerprint covers environment, bundle program and working directory too.
    static let itemPrefix = "item2"
    /// Keys from before that (program and arguments only): upgraded once, never evidence of a change.
    static let previousItemPrefix = "item"
    static let separator = "\u{0}"

    private let keys: Set<String>
    private let labels: Set<String>
    private let paths: Set<String>
    /// The keys the review saved for each kind (plus those saved without a kind); old-style keys match only here.
    /// Nil: a review saved without kinds, whose keys apply to every kind.
    private let byKind: [StartupKind: Set<String>]?

    /// `byKind` holds, for each kind, the keys saved for it plus those saved under no kind.
    public init(_ keys: Set<String>, byKind: [StartupKind: Set<String>]? = nil) {
        self.keys = keys
        self.byKind = byKind
        var labels: Set<String> = []
        var paths: Set<String> = []
        for key in keys {
            let parts = key.components(separatedBy: Self.separator)
            guard parts.count == 4, parts[0] == Self.itemPrefix else { continue }
            if !parts[1].isEmpty {
                labels.insert(parts[1])
            }
            paths.insert(parts[2])
        }
        self.labels = labels
        self.paths = paths
    }

    /// A current key wins; then a label or file the review saw in another form (changed) wins over an old-style
    /// key, so an old key left behind can never hide a change once the item was upgraded. Old-style keys match only
    /// within the item's own kind: a daemon reusing a reviewed agent's label is not reviewed.
    public func match(_ item: StartupItem) -> StartupReviewMatch {
        if keys.contains(item.reviewKey) {
            return .reviewed
        }
        if paths.contains(item.plistPath) || item.validLabel.map(labels.contains) == true {
            return .changed
        }
        if !oldKeys(of: item).isEmpty {
            return .reviewedBeforeUpgrade
        }
        return .new
    }

    /// `match` for a whole listing, plus one rule only a listing can apply: an old label key that more than one
    /// item matches (another file took a reviewed label) cannot say which one was reviewed, so those items are
    /// changed. An item matched by an old key naming its own file stays reviewed.
    public func matches(_ items: [StartupItem]) -> [StartupReviewMatch] {
        var results = items.map(match)
        var uses: [String: Int] = [:]
        for (item, result) in zip(items, results) where result == .reviewedBeforeUpgrade {
            for key in oldKeys(of: item) {
                uses[key, default: 0] += 1
            }
        }
        for index in items.indices where results[index] == .reviewedBeforeUpgrade {
            let matched = oldKeys(of: items[index])
            let byPath = matched.contains { !$0.hasPrefix("label:") }
            if !byPath, matched.contains(where: { (uses[$0] ?? 0) > 1 }) {
                results[index] = .changed
            }
        }
        return results
    }

    private func oldKeys(of item: StartupItem) -> [String] {
        let saved = byKind.map { $0[item.kind] ?? [] } ?? keys
        return item.legacyReviewKeys.filter(saved.contains)
    }

    /// The old-style keys an upgraded item replaces.
    public static func legacyKeys(of item: StartupItem) -> [String] {
        item.legacyReviewKeys
    }
}
