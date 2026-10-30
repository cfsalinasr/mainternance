import Darwin
import Foundation
@testable import MainternanceData
import Testing

/// A temp directory with fixture scripts. `/bin/sh` appears ONLY inside these fixtures; production never uses it.
private final class Fixture {
    let directory: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mainternance-runner-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: directory) }

    func script(_ body: String, name: String = "tool.sh") throws -> String {
        let url = directory.appendingPathComponent(name)
        try ("#!/bin/sh\n" + body + "\n").write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url.path
    }
}

private struct Outcome: Sendable {
    var lines: [ProcessLine]
    var status: Int32
    var stdout: [String] {
        lines.compactMap {
            if case let .stdout(text) = $0 {
                text
            } else {
                nil
            }
        }
    }

    var stderr: [String] {
        lines.compactMap {
            if case let .stderr(text) = $0 {
                text
            } else {
                nil
            }
        }
    }
}

private let runner = SystemProcessRunner()

private func start(_ path: String, _ arguments: [String] = [], env: [String: String]? = nil) -> RunningProcess {
    runner.run(path, arguments: arguments, environment: env, lowPriority: false)
}

private func collect(_ process: RunningProcess) async -> Outcome {
    async let status = process.wait()
    var lines: [ProcessLine] = []
    for await line in process.lines {
        lines.append(line)
    }
    return await Outcome(lines: lines, status: status)
}

/// Runs `operation`; fails the test with a clear message (and returns nil) when it takes longer than `seconds`.
private func within<T: Sendable>(
    _ seconds: Double,
    _ what: String,
    _ operation: @escaping @Sendable () async -> T
) async -> T? {
    let result: T? = await withTaskGroup(of: T?.self) { group in
        group.addTask { await operation() }
        group.addTask {
            try? await Task.sleep(for: .seconds(seconds))
            return nil
        }
        let first = await group.next() ?? nil
        group.cancelAll()
        return first
    }
    if result == nil {
        Issue.record("Timed out after \(seconds)s: \(what)")
    }
    return result
}

private struct Terminated: Sendable {
    var status: Int32
    var elapsed: TimeInterval
    var wasRunning: Bool
}

private func isGone(_ pid: Int32) -> Bool {
    kill(pid, 0) == -1 && errno == ESRCH
}

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

    @Test("low priority still runs the child")
    func lowPriority() async {
        let process = runner.run("/bin/echo", arguments: ["hi"], environment: nil, lowPriority: true)
        let outcome = await within(10, "echo") { await collect(process) }
        #expect(outcome?.stdout == ["hi"])
        #expect(outcome?.status == 0)
    }

    @Test("terminate kills a long running child quickly and reaps it")
    func terminateKills() async throws {
        let fixture = try Fixture()
        let tool = try fixture.script("echo ready\nexec /bin/sleep 30")
        let process = start(tool)
        let pid = try #require(process.processIdentifier)
        let result = await within(10, "terminate") { () -> Terminated? in
            var iterator = process.lines.makeAsyncIterator()
            guard await iterator.next() == .stdout("ready") else { return nil }
            let running = process.isRunning
            let began = Date()
            await process.terminate()
            return await Terminated(
                status: process.wait(),
                elapsed: Date().timeIntervalSince(began),
                wasRunning: running
            )
        }
        let done = try #require(result ?? nil)
        #expect(done.wasRunning)
        #expect(done.status == 143)
        #expect(done.elapsed < 3)
        #expect(!process.isRunning)
        #expect(isGone(pid))
    }

    @Test("a child that ignores SIGTERM is killed by the SIGKILL escalation")
    func killEscalation() async throws {
        let fixture = try Fixture()
        let tool = try fixture.script("trap '' TERM\necho ready\nwhile :; do /bin/sleep 1; done")
        let process = start(tool)
        let pid = try #require(process.processIdentifier)
        let result = await within(15, "escalation") { () -> (Int32, TimeInterval)? in
            var iterator = process.lines.makeAsyncIterator()
            guard await iterator.next() == .stdout("ready") else { return nil }
            let began = Date()
            await process.terminate()
            return await (process.wait(), Date().timeIntervalSince(began))
        }
        let (status, elapsed) = try #require(result ?? nil)
        #expect(status == 137)
        #expect(elapsed >= 1.8 && elapsed < 5)
        #expect(isGone(pid))
    }

    @Test("cancelling the awaiting task terminates the child")
    func cancellation() async throws {
        let fixture = try Fixture()
        let tool = try fixture.script("echo ready\nexec /bin/sleep 30")
        let process = start(tool)
        let pid = try #require(process.processIdentifier)
        let waiter = Task { await process.wait() }
        let outcome = await within(10, "cancel") { () -> Int32? in
            var iterator = process.lines.makeAsyncIterator()
            guard await iterator.next() == .stdout("ready") else { return nil }
            waiter.cancel()
            return await waiter.value
        }
        #expect(try #require(outcome ?? nil) == 143)
        #expect(isGone(pid))
    }

    @Test("terminate after exit is a no-op and the status stays")
    func terminateAfterExit() async throws {
        let fixture = try Fixture()
        let process = try start(fixture.script("exit 5"))
        let outcome = await within(10, "exit") { await collect(process) }
        #expect(outcome?.status == 5)
        await process.terminate()
        await process.terminate()
        #expect(await process.wait() == 5)
        #expect(!process.isRunning)
    }

    @Test("dropping the handle of a running child kills it")
    func droppedHandleKillsChild() async throws {
        let fixture = try Fixture()
        let tool = try fixture.script("echo ready\nexec /bin/sleep 30")
        var pid: Int32 = 0
        do {
            let process = start(tool)
            pid = try #require(process.processIdentifier)
            var iterator = process.lines.makeAsyncIterator()
            #expect(await iterator.next() == .stdout("ready"))
        }
        let deadline = Date().addingTimeInterval(5)
        while !isGone(pid), Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(isGone(pid), "the orphan was not killed")
    }

    @Test("a finished process replays scripted output")
    func finishedFake() async {
        let process = RunningProcess.finished(lines: [.stdout("a"), .stderr("b")], status: 4)
        let outcome = await collect(process)
        #expect(outcome.lines == [.stdout("a"), .stderr("b")])
        #expect(outcome.status == 4)
        #expect(!process.isRunning)
    }
}
