import Darwin
import Foundation
@testable import MainternanceData
import Synchronization
import Testing

@Suite("Process termination")
struct ProcessTerminationTests {
    @Test("terminate kills a long running child quickly and reaps it")
    func terminateKills() async throws {
        let fixture = try Fixture()
        let process = try fixture.start(fixture.script("echo ready\nexec /bin/sleep 20"))
        let pid = try #require(process.processIdentifier)
        let result = await within(10, "terminate") { () -> Terminated? in
            guard await awaitReady(process) != nil else { return nil }
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
        let body = "trap '' TERM\necho ready\ni=0\nwhile [ $i -lt 20 ]; do /bin/sleep 1; i=$((i+1)); done"
        let process = try fixture.start(fixture.script(body))
        let pid = try #require(process.processIdentifier)
        let result = await within(15, "escalation") { () -> Terminated? in
            guard await awaitReady(process) != nil else { return nil }
            let began = Date()
            await process.terminate()
            return await Terminated(status: process.wait(), elapsed: Date().timeIntervalSince(began), wasRunning: true)
        }
        let done = try #require(result ?? nil)
        #expect(done.status == 137)
        #expect(done.elapsed >= 1.8 && done.elapsed < 5)
        #expect(isGone(pid))
    }

    @Test("cancelling the awaiting task terminates the child")
    func cancellation() async throws {
        let fixture = try Fixture()
        let process = try fixture.start(fixture.script("echo ready\nexec /bin/sleep 20"))
        let pid = try #require(process.processIdentifier)
        let waiter = Task { await process.wait() }
        let outcome = await within(10, "cancel") { () -> Int32? in
            guard await awaitReady(process) != nil else { return nil }
            waiter.cancel()
            return await waiter.value
        }
        #expect(try #require(outcome ?? nil) == 143)
        #expect(isGone(pid))
    }

    @Test("terminate after exit is a no-op and the status stays")
    func terminateAfterExit() async throws {
        let fixture = try Fixture()
        let process = try fixture.start(fixture.script("exit 5"))
        let outcome = await within(10, "exit") { await collect(process) }
        #expect(outcome?.status == 5)
        await process.terminate()
        await process.terminate()
        process.terminateNow()
        #expect(await process.wait() == 5)
        #expect(!process.isRunning)
    }

    @Test("dropping the handle of a running child kills it and its group")
    func droppedHandleKillsChild() async throws {
        let fixture = try Fixture()
        var pids: [Int32] = []
        do {
            let process = try start(fixture.lingeringScript())
            pids = try [#require(process.processIdentifier)]
            let grandchild = await within(10, "ready") { await awaitReady(process) }
            try pids.append(#require(grandchild ?? nil))
        }
        for pid in pids {
            #expect(await waitUntilGone(pid), "pid \(pid) was not killed")
        }
    }

    @Test("terminate signals the whole group: a grandchild dies with the child")
    func terminateKillsGroup() async throws {
        let fixture = try Fixture()
        let process = try fixture.start(fixture.lingeringScript())
        let pid = try #require(process.processIdentifier)
        let result = await within(10, "group terminate") { () -> Int32? in
            guard let grandchild = await awaitReady(process) else { return nil }
            await process.terminate()
            return grandchild
        }
        let grandchild = try #require(result ?? nil)
        #expect(grandchild > 1)
        #expect(isGone(pid))
        #expect(await waitUntilGone(grandchild), "the grandchild survived terminate()")
    }

    @Test("the child leads its own process group")
    func childLeadsGroup() async throws {
        let fixture = try Fixture()
        let process = try fixture.start(fixture.script("echo ready\nexec /bin/sleep 20"))
        let pid = try #require(process.processIdentifier)
        _ = await within(10, "ready") { await awaitReady(process) }
        #expect(getpgid(pid) == pid)
        #expect(getpgid(pid) != getpgrp())
    }

    @Test("terminate(killGroup: false) signals only the child")
    func terminateChildOnly() async throws {
        let fixture = try Fixture()
        let process = try fixture.start(fixture.lingeringScript())
        let result = await within(10, "child only") { () -> Int32? in
            guard let grandchild = await awaitReady(process) else { return nil }
            await process.terminate(killGroup: false)
            return grandchild
        }
        let grandchild = try #require(result ?? nil)
        defer { kill(grandchild, SIGKILL) } // bounded fixture, but do not leave it for 20 s
        #expect(grandchild > 1)
        #expect(kill(grandchild, 0) == 0, "the grandchild must survive a child-only terminate")
    }

    @Test("terminateNow kills the child and its grandchild right away, and is idempotent")
    func terminateNowKillsGroup() async throws {
        let fixture = try Fixture()
        let process = try fixture.start(fixture.lingeringScript())
        let pid = try #require(process.processIdentifier)
        let ready = await within(10, "ready") { await awaitReady(process) }
        let grandchild = try #require(ready ?? nil)
        process.terminateNow()
        process.terminateNow()
        let status = await within(5, "wait after terminateNow") { await process.wait() }
        #expect(status == 137)
        #expect(isGone(pid))
        #expect(await waitUntilGone(grandchild), "the grandchild survived terminateNow()")
    }

    @Test("a finished process replays scripted output")
    func finishedFake() async {
        let process = RunningProcess.finished(lines: [.stdout("a"), .stderr("b")], status: 4)
        let outcome = await collect(process)
        #expect(outcome.lines == [.stdout("a"), .stderr("b")])
        #expect(outcome.status == 4)
        #expect(!process.isRunning)
    }

    @Test("a controllable fake runs until finished")
    func controllableFinish() async {
        let calls = Mutex(0)
        let (process, finish) = RunningProcess.controllable(lines: AsyncStream { $0.finish() }) {
            calls.withLock { $0 += 1 }
        }
        #expect(process.isRunning)
        finish(7)
        finish(9)
        #expect(await process.wait() == 7)
        process.terminateNow()
        await process.terminate()
        #expect(calls.withLock { $0 } == 0)
        #expect(!process.isRunning)
    }

    @Test("a controllable fake records terminate and terminateNow")
    func controllableTerminate() async {
        let calls = Mutex(0)
        let first = RunningProcess.controllable(lines: AsyncStream { $0.finish() }) { calls.withLock { $0 += 1 } }
        let termStatus = await within(5, "fake terminate") {
            await first.process.terminate()
            return await first.process.wait()
        }
        #expect(termStatus == 143)
        #expect(calls.withLock { $0 } == 1)
        let second = RunningProcess.controllable(lines: AsyncStream { $0.finish() }) { calls.withLock { $0 += 1 } }
        second.process.terminateNow()
        let nowStatus = await within(5, "fake terminateNow") { await second.process.wait() }
        #expect(nowStatus == 137)
        #expect(calls.withLock { $0 } == 2)
    }
}
