import Foundation
@testable import MainternanceData
import MainternanceDomain
import Synchronization
import Testing

/// Quit handling and failure-message selection of the installer.
@Suite("ClamAV installer quit and failure messages")
struct ClamAVInstallerQuitTests {
    private func installer(tools: FakeTools, runner: ProcessRunning, support: URL) -> ClamAVInstaller {
        ClamAVInstaller(locator: tools.locator, runner: runner, paths: ClamAVPaths(supportDirectory: support))
    }

    private func waitForCalls(_ runner: FakeRunner, _ count: Int) async {
        let deadline = Date().addingTimeInterval(10)
        while runner.recorded.count < count, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    /// The first child hangs until it is signalled. Any later child exits at once, so a regression that lets one
    /// start after a quit fails an expectation instead of hanging the test.
    private func hangingRunner(signals: SignalLog) -> FakeRunner {
        let launches = Mutex(0)
        return FakeRunner { _ in
            let index = launches.withLock { current -> Int in
                defer { current += 1 }
                return current
            }
            guard index == 0 else { return RunningProcess.finished(lines: [], status: 0) }
            let (stream, source) = AsyncStream<ProcessLine>.makeStream()
            let (process, _) = RunningProcess.controllable(lines: stream, onSignal: { signal, _ in
                signals.add(signal)
                source.finish()
            })
            return process
        }
    }

    // `runner.run` and storing the handle happen in one critical section, which `terminateNow()` also takes, so once
    // the runner was called a quit can never miss the child: waiting for the call is enough (no flake window).

    @Test("terminateNow kills a running install, is idempotent, and the app is quitting so nothing starts again")
    func quitHook() async throws {
        let temp = try TempDirectory()
        let signals = SignalLog()
        let runner = hangingRunner(signals: signals)
        let sut = installer(tools: FakeTools(["brew"]), runner: runner, support: temp.url)
        let first = sut.install()
        await waitForCalls(runner, 1)
        sut.terminateNow()
        sut.terminateNow()
        let events = await collectEvents(first)
        #expect(signals.all == [SIGKILL])
        #expect(!events.contains(.finished))
        guard case .failed? = events.last else {
            Issue.record("expected a failure after the kill, got \(events)")
            return
        }
        let second = await collectEvents(sut.install())
        #expect(second == [.failed(message: ClamAVInstaller.quittingMessage)])
        #expect(runner.recorded.count == 1)
    }

    @Test("terminateNow kills a running definitions update the same way")
    func quitHookUpdate() async throws {
        let temp = try TempDirectory()
        let signals = SignalLog()
        let runner = hangingRunner(signals: signals)
        let sut = installer(tools: FakeTools(["freshclam"]), runner: runner, support: temp.url)
        let first = sut.updateDefinitions()
        await waitForCalls(runner, 1)
        sut.terminateNow()
        sut.terminateNow()
        let events = await collectEvents(first)
        #expect(signals.all == [SIGKILL])
        #expect(!events.contains(.finished))
        guard case .failed? = events.last else {
            Issue.record("expected a failure after the kill, got \(events)")
            return
        }
        let second = await collectEvents(sut.updateDefinitions())
        #expect(second == [.failed(message: ClamAVInstaller.quittingMessage)])
        #expect(runner.recorded.count == 1)
    }

    @Test("a quit that lands after the slot is claimed and before the child starts keeps the child from starting")
    func quitBetweenClaimAndStart() async throws {
        let temp = try TempDirectory()
        let tools = FakeTools(["brew", "freshclam"])
        let runner = FakeRunner.replaying([], status: 0)
        let sut = installer(tools: tools, runner: runner, support: temp.url)
        // The lookup of the tool happens after the slot is claimed and before `runner.run`.
        tools.onLookup { _ in sut.terminateNow() }
        let install = await collectEvents(sut.install())
        #expect(install == [.failed(message: ClamAVInstaller.quittingMessage)])
        #expect(runner.recorded.isEmpty)
        let update = await collectEvents(sut.updateDefinitions())
        #expect(update == [.failed(message: ClamAVInstaller.quittingMessage)])
        #expect(runner.recorded.isEmpty)
    }

    @Test("failure message prefers Error lines over a trailing pair of Warning lines")
    func errorLinesBeatWarnings() async throws {
        let temp = try TempDirectory()
        let runner = FakeRunner.replaying([
            .stderr("Error: the real reason"), .stderr("Warning: something odd"), .stderr("Warning: more noise")
        ], status: 1)
        let events = await collectEvents(
            installer(tools: FakeTools(["brew"]), runner: runner, support: temp.url).install()
        )
        guard case let .failed(message)? = events.last else {
            Issue.record("expected a failure, got \(events)")
            return
        }
        #expect(message.contains("Error: the real reason"))
        #expect(!message.contains("Warning"))
    }

    @Test("without any Error line the Warning lines are still reported")
    func warningsAreTheFallback() async throws {
        let temp = try TempDirectory()
        let runner = FakeRunner.replaying([.stderr("Warning: only a warning")], status: 1)
        let events = await collectEvents(
            installer(tools: FakeTools(["brew"]), runner: runner, support: temp.url).install()
        )
        guard case let .failed(message)? = events.last else {
            Issue.record("expected a failure, got \(events)")
            return
        }
        #expect(message.contains("Warning: only a warning"))
    }
}
