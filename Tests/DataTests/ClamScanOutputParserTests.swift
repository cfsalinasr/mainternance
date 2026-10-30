import Foundation
@testable import MainternanceData
import Testing

@Suite("clamscan output parser")
struct ClamScanOutputParserTests {
    private static let cases: [(line: String, expected: ClamLine)] = [
        ("/Users/me/a.txt: OK", .scanned(path: "/Users/me/a.txt")),
        (
            "/Users/me/a.txt: Win.Test.EICAR_HDB-1 FOUND",
            .found(path: "/Users/me/a.txt", signature: "Win.Test.EICAR_HDB-1")
        ),
        ("/x/eicar: Eicar-Signature FOUND", .found(path: "/x/eicar", signature: "Eicar-Signature")),
        // Paths with the separator or the verdict words inside.
        ("/x/a: b: c.txt: OK", .scanned(path: "/x/a: b: c.txt")),
        ("/x/a: b.txt: Eicar-Signature FOUND", .found(path: "/x/a: b.txt", signature: "Eicar-Signature")),
        ("/x/report FOUND: final.txt: OK", .scanned(path: "/x/report FOUND: final.txt")),
        ("/x/bad FOUND: Win.Test.EICAR_HDB-1 FOUND", .found(path: "/x/bad FOUND", signature: "Win.Test.EICAR_HDB-1")),
        ("/x/ERROR: OK: OK", .scanned(path: "/x/ERROR: OK")),
        ("/x/a: OK: Eicar-Signature FOUND", .found(path: "/x/a: OK", signature: "Eicar-Signature")),
        ("/x/a: Foo FOUND: OK", .scanned(path: "/x/a: Foo FOUND")),
        // Unicode and trailing spaces belong to the path.
        ("/Users/josé/ファイル 🦠.txt: OK", .scanned(path: "/Users/josé/ファイル 🦠.txt")),
        ("/x/name : OK", .scanned(path: "/x/name ")),
        ("/x/name  : Eicar-Signature FOUND", .found(path: "/x/name  ", signature: "Eicar-Signature")),
        // Unreadable files, the three permission forms plus a generic error.
        ("/p/secret: Permission denied. ERROR", .unreadable(path: "/p/secret", isPermission: true)),
        ("/p/dir: Can't open file or directory ERROR", .unreadable(path: "/p/dir", isPermission: true)),
        ("/p/Library/Mail: Operation not permitted. ERROR", .unreadable(path: "/p/Library/Mail", isPermission: true)),
        ("/p/a: b: Operation not permitted ERROR", .unreadable(path: "/p/a: b", isPermission: true)),
        ("/p/broken: Can't parse the thing ERROR", .unreadable(path: "/p/broken", isPermission: false)),
        // Informational lines and noise.
        ("/p/empty: Empty file", .ignored),
        ("/p/skipped: Excluded", .ignored),
        ("/p/link: Symbolic link", .ignored),
        ("LibClamAV Warning: something odd", .ignored),
        ("WARNING: Can't open file /p/x: Permission denied", .unreadable(path: "/p/x", isPermission: true)),
        (
            "WARNING: Can't open file /p/a: b/x: Operation not permitted",
            .unreadable(path: "/p/a: b/x", isPermission: true)
        ),
        (
            "WARNING: Can't open file /p/gone: No such file or directory",
            .unreadable(path: "/p/gone", isPermission: false)
        ),
        ("WARNING: Can't open file : Permission denied", .ignored),
        ("/p/priv.txt: Access denied", .unreadable(path: "/p/priv.txt", isPermission: true)),
        ("/p/a: OK: Access denied", .unreadable(path: "/p/a: OK", isPermission: true)),
        ("/p/Library/Safari: Can't open directory.", .unreadable(path: "/p/Library/Safari", isPermission: true)),
        (
            "/p/x: lstat() failed: Permission denied. ERROR",
            .unreadable(path: "/p/x: lstat() failed", isPermission: true)
        ),
        ("Scanning /p/a", .ignored),
        ("Scanning /p/a: OK", .ignored),
        ("Scanning /p/a: Eicar FOUND", .ignored),
        ("relative/path: OK", .ignored),
        ("ERROR: Can't allocate memory", .ignored),
        ("", .ignored),
        ("   ", .ignored),
        (": OK", .ignored),
        ("OK", .ignored),
        ("FOUND", .ignored),
        (" FOUND", .ignored),
        ("no separator FOUND", .ignored),
        ("/x: FOUND", .ignored),
        ("no separator ERROR", .ignored),
        ("----------- SCAN SUMMARY -----------", .ignored)
    ]

    @Test("table", arguments: cases.map(\.line))
    func table(line: String) throws {
        let expected = try #require(Self.cases.first { $0.line == line }).expected
        #expect(ClamScanOutputParser.parse(line) == expected)
    }

    @Test("one line yields one result, never more")
    func oneLineOneResult() {
        // A path that looks like a finding line itself still produces a single, correct result.
        let line = "/x/a: Fake.Sig FOUND/b.txt: OK"
        #expect(ClamScanOutputParser.parse(line) == .scanned(path: "/x/a: Fake.Sig FOUND/b.txt"))
    }
}
