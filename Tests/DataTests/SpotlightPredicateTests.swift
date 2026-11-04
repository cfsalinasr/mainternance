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

    private func names(_ predicate: NSPredicate?, _ name: String) -> Bool {
        predicate?.evaluate(with: ["kMDItemFSName": name]) ?? false
    }

    @Test("a kind filters by file name ending, generated from the FileKind extension table")
    func kinds() throws {
        for kind in FileKind.allCases where kind != .other {
            let extensions = FileKind.extensions(for: kind)
            #expect(!extensions.isEmpty)
            let predicate = try #require(SpotlightPredicate.make(FileSearchQuery(kind: kind)))
            let matches: [NSComparisonPredicate] = if let compound = predicate as? NSCompoundPredicate {
                try compound.subpredicates.map { try #require($0 as? NSComparisonPredicate) }
            } else {
                try [comparison(predicate)]
            }
            #expect(matches.count == extensions.count)
            for match in matches {
                #expect(match.leftExpression.keyPath == "kMDItemFSName")
                #expect(match.predicateOperatorType == .endsWith)
                #expect(match.options == [.caseInsensitive])
                #expect(match.rightExpression.expressionType == .constantValue)
            }
            let suffixes = matches.compactMap { $0.rightExpression.constantValue as? String }
            #expect(Set(suffixes) == Set(extensions.map { "." + $0 }))
        }
    }

    @Test("every extension in the table is matched by exactly one kind's filter, any letter case")
    func everyExtensionOnce() {
        var seen = 0
        for kind in FileKind.allCases where kind != .other {
            for item in FileKind.extensions(for: kind) {
                seen += 1
                for name in ["file.\(item)", "File.\(item.uppercased())"] {
                    let matching = FileKind.allCases.filter {
                        names(SpotlightPredicate.make(FileSearchQuery(kind: $0)), name)
                    }
                    #expect(matching == [kind], "\(name) matched \(matching)")
                }
            }
        }
        #expect(seen > 50)
    }

    @Test("the kind a result is shown with is the kind whose filter matches its name")
    func displayedKindAgrees() {
        let samples = ["notes.txt", "README.md", "data.csv", "index.html", "ci.yml", "photo.JPG", "movie.mov",
                       "song.mp3", "backup.zip", "main.swift", "no-extension", "weird.qqq", "dot.", ".hidden"]
        for name in samples {
            let item = FileItem(path: "/home/\(name)", bytes: 1, modified: Date(), identity: nil)
            let matching = FileKind.allCases.filter {
                names(SpotlightPredicate.make(FileSearchQuery(kind: $0)), name)
            }
            #expect(matching == [item.kind], "\(name): shown \(item.kind), filtered \(matching)")
        }
    }

    @Test("other is everything that is none of the known extensions")
    func otherKind() throws {
        let predicate = try #require(SpotlightPredicate.make(FileSearchQuery(kind: .other)) as? NSCompoundPredicate)
        #expect(predicate.compoundPredicateType == .not)
        let inner = try #require(predicate.subpredicates.first as? NSCompoundPredicate)
        #expect(inner.compoundPredicateType == .or)
        let known = FileKind.allCases.filter { $0 != .other }.flatMap { FileKind.extensions(for: $0) }
        #expect(inner.subpredicates.count == known.count)
        #expect(names(predicate, "mystery.qqq"))
        #expect(!names(predicate, "notes.TXT"))
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
        let first = try #require(predicate.subpredicates[0] as? NSComparisonPredicate)
        let kind = try #require(predicate.subpredicates[1] as? NSCompoundPredicate)
        let rest = try predicate.subpredicates[2...].map { try #require($0 as? NSComparisonPredicate) }
        #expect(first.leftExpression.keyPath == "kMDItemDisplayName")
        #expect(kind.compoundPredicateType == .or)
        #expect(kind.subpredicates.count == FileKind.extensions(for: .document).count)
        #expect(rest.map(\.leftExpression.keyPath) == ["kMDItemFSSize", "kMDItemFSContentChangeDate"])
    }
}
