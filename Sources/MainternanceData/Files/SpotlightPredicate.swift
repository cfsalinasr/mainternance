import Foundation
import MainternanceDomain

/// Builds the Spotlight predicate for a file search.
///
/// Every value is a constant expression, never part of a format string, so quotes, `*`, `\`, `%` and `@` in the
/// owner's text cannot change what the predicate means.
enum SpotlightPredicate {
    /// nil for an empty query.
    static func make(_ query: FileSearchQuery) -> NSPredicate? {
        var parts: [NSPredicate] = []
        let text = query.trimmedText
        if !text.isEmpty {
            parts.append(NSComparisonPredicate(
                leftExpression: NSExpression(forKeyPath: "kMDItemDisplayName"),
                rightExpression: NSExpression(forConstantValue: text),
                modifier: .direct, type: .contains, options: [.caseInsensitive, .diacriticInsensitive]
            ))
        }
        if let kind = query.kind {
            parts.append(kindPredicate(kind))
        }
        if query.minimumBytes > 0 {
            parts.append(comparison("kMDItemFSSize", .greaterThanOrEqualTo, NSNumber(value: query.minimumBytes)))
        }
        if let date = query.modifiedAfter {
            parts.append(comparison("kMDItemFSContentChangeDate", .greaterThanOrEqualTo, date as NSDate))
        }
        switch parts.count {
        case 0: return nil
        case 1: return parts[0]
        default: return NSCompoundPredicate(andPredicateWithSubpredicates: parts)
        }
    }

    /// A kind is the file names ending in one of its extensions, from the `FileKind` table: the same table that
    /// labels each result, so the filter and the label cannot disagree. `.other` is none of the known extensions.
    private static func kindPredicate(_ kind: FileKind) -> NSPredicate {
        if kind == .other {
            let known = FileKind.allCases.filter { $0 != .other }.flatMap(FileKind.extensions(for:)).map(nameEnding)
            return NSCompoundPredicate(notPredicateWithSubpredicate: NSCompoundPredicate(
                orPredicateWithSubpredicates: known
            ))
        }
        let matches = FileKind.extensions(for: kind).map(nameEnding)
        return matches.count == 1 ? matches[0] : NSCompoundPredicate(orPredicateWithSubpredicates: matches)
    }

    private static func nameEnding(_ pathExtension: String) -> NSPredicate {
        NSComparisonPredicate(
            leftExpression: NSExpression(forKeyPath: "kMDItemFSName"),
            rightExpression: NSExpression(forConstantValue: "." + pathExtension),
            modifier: .direct, type: .endsWith, options: [.caseInsensitive]
        )
    }

    private static func comparison(
        _ key: String, _ type: NSComparisonPredicate.Operator, _ value: Any
    ) -> NSComparisonPredicate {
        NSComparisonPredicate(
            leftExpression: NSExpression(forKeyPath: key), rightExpression: NSExpression(forConstantValue: value),
            modifier: .direct, type: type, options: []
        )
    }
}
