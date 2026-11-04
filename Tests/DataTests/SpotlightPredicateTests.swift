import Foundation
@testable import MainternanceData
import MainternanceDomain
import Testing

/// The Spotlight predicate is built from constant values, so no query text can change its shape. Spotlight itself is
/// never queried here.
@Suite("Spotlight predicate")
struct SpotlightPredicateTests {
    private func comparison(_ predicate: NSPredicate?) throws -> NSComparisonPredicate {
        try #require(predicate as? NSComparisonPredicate)
    }

    private func parts(_ predicate: NSPredicate?, orSingle _: Bool) throws -> [NSComparisonPredicate] {
        if let compound = predicate as? NSCompoundPredicate {
            return try compound.subpredicates.map { try #require($0 as? NSComparisonPredicate) }
        }
        return try [comparison(predicate)]
    }

    @Test("an empty query gives no predicate; spaces alone are empty")
    func emptyQuery() {
        #expect(FileSearchQuery().isEmpty)
        #expect(SpotlightPredicate.make(FileSearchQuery()) == nil)
        #expect(SpotlightPredicate.make(FileSearchQuery(text: "  \n ")) == nil)
        #expect(!FileSearchQuery(text: "a").isEmpty)
        #expect(!FileSearchQuery(kind: .image).isEmpty)
        #expect(!FileSearchQuery(minimumBytes: 1).isEmpty)
        #expect(!FileSearchQuery(modifiedAfter: Date()).isEmpty)
    }

    @Test("name text is a case and diacritic insensitive contains on the display name")
    func nameText() throws {
        let predicate = try comparison(SpotlightPredicate.make(FileSearchQuery(text: "Résumé")))
        #expect(predicate.leftExpression.keyPath == "kMDItemDisplayName")
        #expect(predicate.rightExpression.constantValue as? String == "Résumé")
        #expect(predicate.predicateOperatorType == .contains)
        #expect(predicate.options == [.caseInsensitive, .diacriticInsensitive])
    }

    @Test("quotes, stars, backslashes and percent signs stay literal text")
    func literalText() throws {
        for text in [#"a"b"#, "it's", "*", "a*b?", #"c:\temp"#, "100%", "%@", "x\" || kMDItemFSSize > 0 || \"y"] {
            let predicate = try comparison(SpotlightPredicate.make(FileSearchQuery(text: text)))
            #expect(predicate.rightExpression.expressionType == .constantValue)
            #expect(predicate.rightExpression.constantValue as? String == text)
            #expect(predicate.leftExpression.keyPath == "kMDItemDisplayName")
        }
    }

    @Test("the text is trimmed of surrounding spaces")
    func trimmed() throws {
        let predicate = try comparison(SpotlightPredicate.make(FileSearchQuery(text: "  report \n")))
        #expect(predicate.rightExpression.constantValue as? String == "report")
    }

    @Test("every kind but other matches its content types through the content-type tree")
    func kinds() throws {
        for kind in FileKind.allCases where kind != .other {
            let types = SpotlightPredicate.contentTypes(for: kind)
            #expect(!types.isEmpty)
            let predicate = try #require(SpotlightPredicate.make(FileSearchQuery(kind: kind)))
            let matches = try parts(predicate, orSingle: true)
            #expect(matches.count == types.count)
            for match in matches {
                #expect(match.leftExpression.keyPath == "kMDItemContentTypeTree")
                #expect(match.predicateOperatorType == .equalTo)
                #expect(types.contains(match.rightExpression.constantValue as? String ?? ""))
            }
        }
        #expect(SpotlightPredicate.contentTypes(for: .image) == ["public.image"])
        #expect(SpotlightPredicate.contentTypes(for: .video).contains("public.movie"))
        #expect(SpotlightPredicate.contentTypes(for: .audio) == ["public.audio"])
    }

    @Test("other is everything that is none of the named kinds")
    func otherKind() throws {
        let predicate = try #require(SpotlightPredicate.make(FileSearchQuery(kind: .other)) as? NSCompoundPredicate)
        #expect(predicate.compoundPredicateType == .not)
        let inner = try #require(predicate.subpredicates.first as? NSCompoundPredicate)
        #expect(inner.compoundPredicateType == .or)
        let named = FileKind.allCases.filter { $0 != .other }.flatMap { SpotlightPredicate.contentTypes(for: $0) }
        #expect(inner.subpredicates.count == named.count)
    }

    @Test("minimum size is a greater-or-equal on the file size, as a number")
    func minimumSize() throws {
        let predicate = try comparison(SpotlightPredicate.make(FileSearchQuery(minimumBytes: 5_000_000_000)))
        #expect(predicate.leftExpression.keyPath == "kMDItemFSSize")
        #expect(predicate.predicateOperatorType == .greaterThanOrEqualTo)
        #expect((predicate.rightExpression.constantValue as? NSNumber)?.int64Value == 5_000_000_000)
        #expect(SpotlightPredicate.make(FileSearchQuery(minimumBytes: -5)) == nil)
    }

    @Test("changed after is a greater-or-equal on the content change date")
    func changedAfter() throws {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let predicate = try comparison(SpotlightPredicate.make(FileSearchQuery(modifiedAfter: date)))
        #expect(predicate.leftExpression.keyPath == "kMDItemFSContentChangeDate")
        #expect(predicate.predicateOperatorType == .greaterThanOrEqualTo)
        #expect(predicate.rightExpression.constantValue as? Date == date)
    }

    @Test("several filters are all required")
    func combined() throws {
        let query = FileSearchQuery(
            text: "tax", kind: .document, minimumBytes: 10, modifiedAfter: Date(timeIntervalSince1970: 1)
        )
        let predicate = try #require(SpotlightPredicate.make(query) as? NSCompoundPredicate)
        #expect(predicate.compoundPredicateType == .and)
        #expect(predicate.subpredicates.count == 4)
        let keys = predicate.subpredicates.compactMap { ($0 as? NSComparisonPredicate)?.leftExpression.keyPath }
        #expect(keys == ["kMDItemDisplayName", "kMDItemFSSize", "kMDItemFSContentChangeDate"])
    }
}
