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
    @Test("the count written by the clause is the count read back")
    func roundTrip() {
        for count in [1, 2, 17] {
            let message = "The scan failed (exit 3) after reporting 2 findings" + ScanFailureNote
                .unattributedClause(count)
                + ": ERROR: disk"
            #expect(ScanFailureNote.unattributedCount(in: message) == count)
        }
    }

    @Test("no clause means 0, and only the first clause counts")
    func firstOnly() {
        #expect(ScanFailureNote.unattributedCount(in: "The scan failed (exit 2)") == 0)
        #expect(ScanFailureNote.unattributedCount(in: "") == 0)
        let hostile = "The scan failed (exit 2)" + ScanFailureNote.unattributedClause(2) + ": "
            + ScanFailureNote.unattributedClause(99)
        #expect(ScanFailureNote.unattributedCount(in: hostile) == 2)
        #expect(ScanFailureNote.unattributedCount(in: "99 detection(s) could not be attributed") == 0)
    }

    @Test("the clause wording is pinned")
    func wording() {
        #expect(ScanFailureNote.unattributedClause(3) == " and 3 detection(s) could not be attributed to a file")
    }
}
