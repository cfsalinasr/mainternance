@testable import MainternanceData
import Testing

@Suite("ToolLocator")
struct ToolLocatorTests {
    private func locator(existing: Set<String>, candidates: [String] = ["/first", "/second"]) -> ToolLocator {
        ToolLocator(candidates: candidates, isExecutable: { existing.contains($0) })
    }

    @Test("returns the first candidate that holds the tool")
    func firstCandidateWins() {
        let sut = locator(existing: ["/first/brew", "/second/brew"])
        #expect(sut.path(for: "brew") == "/first/brew")
    }

    @Test("falls through to the next candidate")
    func fallsThrough() {
        let sut = locator(existing: ["/second/clamscan"])
        #expect(sut.path(for: "clamscan") == "/second/clamscan")
    }

    @Test("is nil when no candidate has the tool")
    func missing() {
        #expect(locator(existing: ["/first/brew"]).path(for: "freshclam") == nil)
        #expect(locator(existing: []).path(for: "brew") == nil)
    }

    @Test("tolerates a trailing slash and skips relative candidates")
    func candidateShapes() {
        let sut = locator(existing: ["/first/brew", "relative/brew"], candidates: ["relative", "/first/"])
        #expect(sut.path(for: "brew") == "/first/brew")
    }

    @Test(
        "rejects unsafe or unlisted names even when such a file exists",
        arguments: ["", "/bin/sh", "../brew", "..", "a/../brew", "brew/", "./brew", "Brew", "BREW", "clamdscan",
                    "sh", " brew", "brew ", "brew\n"]
    )
    func rejectsNames(name: String) {
        let everything = Set(["/first", "/second"].flatMap { dir in
            [name, "brew", "clamscan", "freshclam", "clamdscan", "sh"].map { "\(dir)/\($0)" }
        })
        #expect(locator(existing: everything).path(for: name) == nil)
    }

    @Test("every allowed tool can be located")
    func allowList() {
        #expect(ToolLocator.allowedTools == ["brew", "clamscan", "freshclam"])
        let sut = locator(existing: ["/first/brew", "/first/clamscan", "/first/freshclam"])
        for tool in ToolLocator.allowedTools {
            #expect(sut.path(for: tool) == "/first/\(tool)")
        }
    }

    @Test("the default check rejects directories and missing files")
    func defaultCheck() {
        #expect(ToolLocator.isRegularExecutable("/bin/sh"))
        #expect(!ToolLocator.isRegularExecutable("/usr/bin"))
        #expect(!ToolLocator.isRegularExecutable("/definitely/not/here"))
    }
}
