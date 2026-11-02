import Foundation
@testable import MainternanceData
import MainternanceDomain
import Testing

@Suite("scan scopes")
struct ScanScopesTests {
    private let home = URL(fileURLWithPath: "/Users/tester", isDirectory: true)

    private func roots(_ scope: ScanScope, existing: Set<String>?) -> [String] {
        ScanScopes.roots(for: scope, home: home, exists: { existing?.contains($0) ?? true })
    }

    @Test("quick scan lists the six folders in a stable order")
    func quickOrder() {
        #expect(roots(.quick, existing: nil) == [
            "/Users/tester/Downloads", "/Users/tester/Desktop", "/Applications",
            "/Users/tester/Library/LaunchAgents", "/Library/LaunchAgents", "/Library/LaunchDaemons"
        ])
    }

    @Test("only existing folders are kept")
    func existenceFiltering() {
        let existing: Set = ["/Applications", "/Users/tester/Desktop"]
        #expect(roots(.quick, existing: existing) == ["/Users/tester/Desktop", "/Applications"])
        #expect(roots(.quick, existing: []).isEmpty)
        #expect(roots(.custom(URL(fileURLWithPath: "/nope")), existing: []).isEmpty)
    }

    @Test("full scan is the home folder and /Applications")
    func fullScope() {
        #expect(roots(.full, existing: nil) == ["/Users/tester", "/Applications"])
    }

    @Test("custom scope is that folder, standardized")
    func custom() {
        #expect(roots(.custom(URL(fileURLWithPath: "/Users/tester/Documents/../Projects/")), existing: nil)
            == ["/Users/tester/Projects"])
    }

    @Test("a folder nested inside another root is dropped, wherever it is listed")
    func nestedDropped() {
        // Home contains Downloads and Desktop, so a full scan of an odd home keeps only the outer roots.
        let outer = URL(fileURLWithPath: "/Applications", isDirectory: true)
        let scoped = ScanScopes.roots(for: .quick, home: outer, exists: { _ in true })
        // home = /Applications: Downloads, Desktop, Library/LaunchAgents are inside /Applications.
        #expect(scoped == ["/Applications", "/Library/LaunchAgents", "/Library/LaunchDaemons"])
        // A sibling that merely shares a prefix is NOT nested.
        let sibling = URL(fileURLWithPath: "/Applications Extra", isDirectory: true)
        let both = ScanScopes.roots(for: .full, home: sibling, exists: { $0.hasPrefix("/Applications") })
        #expect(both == ["/Applications Extra", "/Applications"])
    }

    @Test("duplicates are removed")
    func dedupe() {
        let scoped = ScanScopes.roots(for: .full, home: URL(fileURLWithPath: "/Applications/"), exists: { _ in true })
        #expect(scoped == ["/Applications"])
    }

    @Test("the root of the disk is never returned")
    func neverSlash() {
        #expect(roots(.custom(URL(fileURLWithPath: "/")), existing: nil).isEmpty)
        #expect(roots(.custom(URL(fileURLWithPath: "/Users/..")), existing: nil).isEmpty)
        let atRoot = ScanScopes.roots(for: .full, home: URL(fileURLWithPath: "/"), exists: { _ in true })
        #expect(atRoot == ["/Applications"])
        for scope in [ScanScope.quick, .full] {
            #expect(!ScanScopes.roots(for: scope, home: URL(fileURLWithPath: "/"), exists: { _ in true }).contains("/"))
        }
    }

    @Test("every root is absolute")
    func absolute() {
        for scope in [ScanScope.quick, .full, .custom(URL(fileURLWithPath: "relative/dir"))] {
            for path in roots(scope, existing: nil) {
                #expect(path.hasPrefix("/"))
            }
        }
    }

    @Test("odd names survive verbatim")
    func oddNames() {
        let name = "-rf $(x) ; y"
        let url = URL(fileURLWithPath: "/Users/tester/\(name)")
        #expect(roots(.custom(url), existing: nil) == ["/Users/tester/\(name)"])
    }
}
