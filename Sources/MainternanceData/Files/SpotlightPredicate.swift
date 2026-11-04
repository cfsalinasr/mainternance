import Foundation
import MainternanceDomain

/// Builds the Spotlight predicate for a file search.
///
/// Every value is a constant expression, never part of a format string, so quotes, `*`, `\`, `%` and `@` in the
/// owner's text cannot change what the predicate means.
enum SpotlightPredicate {
    /// Spotlight's content types per kind (matched against the whole type tree, so subtypes count). `.other` has
    /// none: it is built as "none of the others".
    static func contentTypes(for kind: FileKind) -> [String] {
        switch kind {
        case .document: ["com.adobe.pdf", "public.composite-content", "public.presentation", "public.spreadsheet"]
        case .image: ["public.image"]
        case .video: ["public.movie"]
        case .audio: ["public.audio"]
        case .archive: ["public.archive", "public.disk-image"]
        case .code: ["public.source-code", "public.script", "public.json", "public.xml"]
        case .other: []
        }
    }

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

    private static func kindPredicate(_ kind: FileKind) -> NSPredicate {
        if kind == .other {
            let named = FileKind.allCases.filter { $0 != .other }.flatMap(contentTypes(for:)).map(treeMatch)
            return NSCompoundPredicate(notPredicateWithSubpredicate: NSCompoundPredicate(
                orPredicateWithSubpredicates: named
            ))
        }
        let matches = contentTypes(for: kind).map(treeMatch)
        return matches.count == 1 ? matches[0] : NSCompoundPredicate(orPredicateWithSubpredicates: matches)
    }

    private static func treeMatch(_ type: String) -> NSPredicate {
        comparison("kMDItemContentTypeTree", .equalTo, type)
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
