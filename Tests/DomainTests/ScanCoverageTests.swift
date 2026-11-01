import Foundation
import MainternanceDomain
import Testing

@Suite("Scan coverage")
struct ScanCoverageTests {
    private let coverage = ScanCoverage(
        roots: ["/Users/a/Documents", "/Applications"],
        excluded: ["/Users/a/Library/Mobile Documents", "/Users/a/Documents/Cloud"]
    )

    @Test("a path under a root is covered, the root itself too")
    func underRoot() {
        #expect(coverage.covers("/Users/a/Documents/x.pkg"))
        #expect(coverage.covers("/Users/a/Documents/deep/er/x.pkg"))
        #expect(coverage.covers("/Users/a/Documents"))
        #expect(coverage.covers("/Applications/Evil.app/Contents/x"))
    }

    @Test("whole path components are compared, not string prefixes")
    func components() {
        #expect(!coverage.covers("/Users/a/Documents2/x.pkg"))
        #expect(!coverage.covers("/Users/a/DocumentsOld/x"))
        #expect(!coverage.covers("/ApplicationsExtra/x"))
    }

    @Test("a path outside every root is not covered")
    func outside() {
        #expect(!coverage.covers("/Library/LaunchDaemons/evil.plist"))
        #expect(!coverage.covers("/Users/a/Downloads/x"))
        #expect(!coverage.covers("relative/path"))
        #expect(!coverage.covers(""))
    }

    @Test("an excluded folder wins over a root that contains it")
    func excluded() {
        #expect(!coverage.covers("/Users/a/Documents/Cloud/x.pkg"))
        #expect(!coverage.covers("/Users/a/Documents/Cloud"))
        #expect(coverage.covers("/Users/a/Documents/CloudNotExcluded/x"))
    }

    @Test("dots and double slashes are standardized before comparing")
    func standardized() {
        #expect(coverage.covers("/Users/a/Documents/../Documents//x.pkg"))
        #expect(!coverage.covers("/Users/a/Documents/Cloud/../Cloud/x"))
        #expect(!coverage.covers("/Users/a/Documents/../Downloads/x"))
    }

    @Test("no roots covers nothing")
    func empty() {
        #expect(!ScanCoverage(roots: [], excluded: []).covers("/Users/a/x"))
    }
}

@Suite("Scan failure note")
struct ScanFailureNoteTests {
    @Test("the clause wording is pinned")
    func wording() {
        #expect(ScanFailureNote.unattributedClause(3) == " and 3 detection(s) could not be attributed to a file")
    }
}

@Suite("Scan coverage with symbolic links")
struct ScanCoverageResolverTests {
    private func coverage(_ table: [String: String]) -> ScanCoverage {
        ScanCoverage(roots: ["/real/Downloads"], excluded: ["/real/Downloads/Cloud"], resolve: { table[$0] })
    }

    @Test("the finding's path is resolved before it is compared")
    func resolved() {
        let sut = coverage(["/Users/a/Downloads/x": "/real/Downloads/x", "/Users/a/Other/x": "/elsewhere/x"])
        #expect(sut.covers("/Users/a/Downloads/x"))
        #expect(!sut.covers("/Users/a/Other/x"))
    }

    @Test("a path that cannot be resolved is not covered")
    func unknown() {
        #expect(!coverage([:]).covers("/real/Downloads/x"))
    }

    @Test("exclusions apply to the resolved path")
    func excludedAfterResolving() {
        let sut = coverage(["/Users/a/Link/x": "/real/Downloads/Cloud/x"])
        #expect(!sut.covers("/Users/a/Link/x"))
    }

    @Test("without a resolver paths are compared as text")
    func textOnly() {
        #expect(ScanCoverage(roots: ["/a"], excluded: []).covers("/a/x"))
    }
}
