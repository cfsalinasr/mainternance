import Darwin
import Foundation
@testable import MainternanceData
import Synchronization
import Testing

@Suite("SystemProcessRunner")
struct SystemProcessRunnerTests {
    @Test("streams stdout and stderr separately and in order")
    func separateStreams() async throws {
        let fixture = try Fixture()
        let tool = try fixture.script("echo o1; echo e1 >&2; echo o2; echo e2 >&2; echo o3")
        let outcome = await within(10, "collect") { await collect(start(tool)) }
        #expect(outcome?.stdout == ["o1", "o2", "o3"])
        #expect(outcome?.stderr == ["e1", "e2"])
        #expect(outcome?.status == 0)
    }

    @Test("output far larger than the pipe buffer does not deadlock")
    func largeOutput() async throws {
        let fixture = try Fixture()
        let tool = try fixture.script("/usr/bin/seq 1 50000 >&2 &\n/usr/bin/seq 1 200000\nwait")
        let outcome = await within(20, "large output") { await collect(start(tool)) }
        let result = try #require(outcome)
        #expect(result.stdout.count == 200_000)
        #expect(result.stdout.first == "1" && result.stdout.last == "200000")
        #expect(result.stdout == (1 ... 200_000).map(String.init))
        #expect(result.stderr == (1 ... 50000).map(String.init))
        #expect(result.status == 0)
    }

    @Test("a final line without a newline is flushed, and CRLF is trimmed")
    func finalPartialLine() async {
        let outcome = await within(10, "printf") {
            await collect(start("/usr/bin/printf", ["one\r\ntwo\n\nthree"]))
        }
        #expect(outcome?.stdout == ["one", "two", "", "three"])
    }

    @Test("invalid UTF-8 is replaced, not dropped")
    func invalidUTF8() async {
        let outcome = await within(10, "printf") { await collect(start("/usr/bin/printf", ["a\\377b\\n\\303"])) }
        #expect(outcome?.stdout == ["a\u{FFFD}b", "\u{FFFD}"])
    }

    @Test("reports a non-zero exit status and 128 + signal for a killed child")
    func exitStatuses() async throws {
        let fixture = try Fixture()
        let failing = try fixture.script("exit 3", name: "fail.sh")
        let killed = try fixture.script("kill -9 $$", name: "killed.sh")
        let failedOutcome = await within(10, "exit 3") { await collect(start(failing)) }
        let killedOutcome = await within(10, "kill -9") { await collect(start(killed)) }
        #expect(failedOutcome?.status == 3)
        #expect(killedOutcome?.status == 137)
    }

    @Test("a missing executable reports 127 and one stderr line")
    func missingExecutable() async {
        let process = start("/definitely/not/here/tool")
        let outcome = await within(10, "missing") { await collect(process) }
        #expect(outcome?.status == 127)
        #expect(outcome?.stdout == [])
        #expect(outcome?.stderr.count == 1)
        #expect(outcome?.stderr.first?.contains("/definitely/not/here/tool") == true)
        #expect(process.processIdentifier == nil)
        #expect(!process.isRunning)
        await process.terminate()
    }

    @Test("hostile arguments reach the child verbatim and nothing is executed")
    func argumentsVerbatim() async throws {
        let fixture = try Fixture()
        let pwned = fixture.directory.appendingPathComponent("pwned-\(UUID().uuidString)").path
        let tool = try fixture.script("for a in \"$@\"; do printf 'ARG<%s>END\\n' \"$a\"; done")
        let hostile = [
            "with space", "q\"uote'single", "semi;colon", "$(touch \(pwned))", "`touch \(pwned)`",
            "x && touch \(pwned)",
            "-n", "--help", "", "line1\nline2", "back\\slash", "*", "~"
        ]
        let outcome = await within(10, "argv") { await collect(start(tool, hostile)) }
        let expected = hostile.map { "ARG<\($0)>END" }.joined(separator: "\n")
        #expect(outcome?.stdout.joined(separator: "\n") == expected)
        #expect(outcome?.status == 0)
        #expect(!FileManager.default.fileExists(atPath: pwned))
    }

    @Test("the environment is merged over the current one")
    func mergedEnvironment() async throws {
        let fixture = try Fixture()
        let tool = try fixture.script("echo \"PATH=$PATH\"; echo \"KEY=$MAINT_TEST_KEY\"")
        let currentPath = try #require(ProcessInfo.processInfo.environment["PATH"])
        let merged = await within(10, "env") { await collect(start(tool, env: ["MAINT_TEST_KEY": "va lue"])) }
        #expect(merged?.stdout == ["PATH=\(currentPath)", "KEY=va lue"])
        let untouched = await within(10, "env nil") { await collect(start(tool)) }
        #expect(untouched?.stdout == ["PATH=\(currentPath)", "KEY="])
    }

    @Test("low priority still runs a fixture child to a clean exit")
    func lowPriority() async throws {
        let fixture = try Fixture()
        let tool = try fixture.script("echo hi")
        let process = runner.run(tool, arguments: [], environment: nil, lowPriority: true)
        let outcome = await within(10, "low priority") { await collect(process) }
        #expect(outcome?.stdout == ["hi"])
        #expect(outcome?.status == 0)
    }

    @Test("a non-absolute executable takes the launch-failure path", arguments: ["", "tool", "relative/tool", "./tool"])
    func nonAbsoluteExecutable(path: String) async {
        let process = start(path)
        let outcome = await within(10, "relative") { await collect(process) }
        #expect(outcome?.status == 127)
        #expect(outcome?.stderr.count == 1)
        #expect(outcome?.stdout == [])
        #expect(process.processIdentifier == nil)
        #expect(!process.isRunning)
    }
}
