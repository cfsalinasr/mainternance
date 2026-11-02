import Darwin
import Foundation
@testable import MainternanceData
import MainternanceDomain
import Testing

@Suite("scan exclusions")
struct ScanExclusionsTests {
    /// Real POSIX extended regex matching, the engine clamscan uses (unanchored search).
    private func matches(_ pattern: String, _ text: String) -> Bool {
        var compiled = regex_t()
        guard regcomp(&compiled, pattern, REG_EXTENDED | REG_NOSUB) == 0 else { return false }
        defer { regfree(&compiled) }
        return regexec(&compiled, text, 0, nil, 0) == 0
    }

    @Test("the pattern matches the directory and everything below it, nothing else", arguments: [
        "/Users/me/Library/Application Support/Mainternance/Quarantine",
        "/Users/me/dir.with.dots", "/Users/me/c++ (copy) [1]", "/Users/me/a{1}|b^$*?", "/Users/josé/ファイル 🦠",
        "/Users/me/back\\slash"
    ])
    func escaping(directory: String) {
        let pattern = ScanExclusions.regex(forDirectory: directory)
        #expect(matches(pattern, directory))
        #expect(matches(pattern, directory + "/inner/file.txt"))
        #expect(!matches(pattern, directory + "2"))
        #expect(!matches(pattern, directory + "x/inner"))
        #expect(!matches(pattern, "/prefix" + directory))
        #expect(!matches(pattern, String(directory.dropLast())))
    }

    @Test("metacharacters are not interpreted")
    func notInterpreted() {
        let pattern = ScanExclusions.regex(forDirectory: "/Users/me/a.b")
        #expect(!matches(pattern, "/Users/me/aXb"))
        let plus = ScanExclusions.regex(forDirectory: "/Users/me/c++")
        #expect(!matches(plus, "/Users/me/ccc"))
        let alt = ScanExclusions.regex(forDirectory: "/Users/me/a|b")
        #expect(!matches(alt, "/Users/me/b"))
        #expect(!matches(alt, "b"))
    }

    @Test("directories per scope")
    func perScope() {
        let home = URL(fileURLWithPath: "/Users/tester", isDirectory: true)
        let paths =
            ClamAVPaths(
                supportDirectory: URL(fileURLWithPath: "/Users/tester/Library/Application Support/Mainternance")
            )
        let base = [
            "/Users/tester/Library/Application Support/Mainternance/Quarantine",
            "/Users/tester/Library/Application Support/Mainternance/ClamAV"
        ]
        #expect(ScanExclusions.directories(for: .quick, home: home, paths: paths) == base)
        #expect(ScanExclusions.directories(for: .custom(home), home: home, paths: paths) == base)
        #expect(ScanExclusions.directories(for: .full, home: home, paths: paths)
            == base + ["/Users/tester/Library/Mobile Documents", "/Users/tester/Library/CloudStorage"])
    }

    @Test("every directory is exactly one argument, whatever its name")
    func oneArgumentEach() {
        let hostile = URL(fileURLWithPath: "/tmp/x --exclude-dir=.* \n --infected $(y)", isDirectory: true)
        let paths = ClamAVPaths(supportDirectory: hostile)
        let directories = ScanExclusions.directories(for: .quick, home: hostile, paths: paths)
        let arguments = ScanExclusions.arguments(for: directories)
        #expect(arguments.count == directories.count)
        #expect(directories.count == 2)
        for argument in arguments {
            #expect(argument.hasPrefix("--exclude-dir=^"))
        }
    }
}
