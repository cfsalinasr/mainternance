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
public struct StartupReviewBaseline: Sendable {
    static let itemPrefix = "item"
    static let separator = "\u{0}"

    private let keys: Set<String>
    private let labels: Set<String>
    private let paths: Set<String>

    public init(_ keys: Set<String>) {
        self.keys = keys
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
    /// key, so an old key left behind can never hide a change once the item was upgraded.
    public func match(_ item: StartupItem) -> StartupReviewMatch {
        if keys.contains(item.reviewKey) {
            return .reviewed
        }
        if paths.contains(item.plistPath) || item.validLabel.map(labels.contains) == true {
            return .changed
        }
        if item.legacyReviewKeys.contains(where: keys.contains) {
            return .reviewedBeforeUpgrade
        }
        return .new
    }

    /// The old-style keys an upgraded item replaces.
    public static func legacyKeys(of item: StartupItem) -> [String] {
        item.legacyReviewKeys
    }
}
