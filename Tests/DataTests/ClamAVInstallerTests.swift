import Foundation
@testable import MainternanceData
import MainternanceDomain
import Synchronization
import Testing

final class SignalLog: Sendable {
    private let values = Mutex<[Int32]>([])

    func add(_ value: Int32) {
        values.withLock { $0.append(value) }
    }

    var all: [Int32] {
        values.withLock { $0 }
    }
}

@Suite("ClamAV installer")
struct ClamAVInstallerTests {
    private func installer(
        tools: FakeTools,
        runner: ProcessRunning,
        support: URL
    ) -> ClamAVInstaller {
        ClamAVInstaller(locator: tools.locator, runner: runner, paths: ClamAVPaths(supportDirectory: support))
    }

    // MARK: install

    @Test("without Homebrew it fails with guidance and starts no process")
    func brewMissing() async throws {
        let temp = try TempDirectory()
        let runner = FakeRunner.replaying([], status: 0)
        let events = await collectEvents(
            installer(tools: FakeTools([]), runner: runner, support: temp.url).install()
        )
        #expect(events == [.failed(message: "Homebrew was not found. Install it from https://brew.sh and try again.")])
        #expect(runner.recorded.isEmpty)
    }

    @Test("isInstalled needs both clamscan and freshclam")
    func isInstalled() throws {
        let temp = try TempDirectory()
        let runner = FakeRunner.replaying([], status: 0)
        func check(_ names: Set<String>) -> Bool {
            installer(tools: FakeTools(names), runner: runner, support: temp.url).isInstalled()
        }
        #expect(!check([]))
        #expect(!check(["clamscan"]))
        #expect(!check(["freshclam", "brew"]))
        #expect(check(["clamscan", "freshclam"]))
    }

    @Test("success: exact invocation, environment, no sudo, stages, finished")
    func installSuccess() async throws {
        let temp = try TempDirectory()
        let tools = FakeTools(["brew"])
        let runner = FakeRunner.replaying([
            .stdout("==> Fetching clamav"), .stdout("==> Downloading https://ghcr.io/v2/homebrew/core/clamav"),
            .stdout("some unknown noise"), .stdout("==> Downloading https://ghcr.io/v2/homebrew/core/pcre2"),
            .stdout("==> Pouring clamav--1.5.4.arm64_sequoia.bottle.tar.gz"), .stderr("warning: whatever"),
            .stdout("==> Summary")
        ], status: 0, sideEffect: { tools.add(["clamscan", "freshclam"]) })
        let events = await collectEvents(installer(tools: tools, runner: runner, support: temp.url).install())
        #expect(events == [
            .stage("Downloading ClamAV…"), .stage("Installing ClamAV…"), .stage("Finishing…"), .finished
        ])
        let call = try #require(runner.recorded.first)
        #expect(runner.recorded.count == 1)
        #expect(call.executable == "/fake/bin/brew")
        #expect(call.arguments == ["install", "clamav"])
        #expect(call.environment?["HOMEBREW_NO_AUTO_UPDATE"] == "1")
        #expect(call.environment?["HOMEBREW_NO_ENV_HINTS"] == "1")
        #expect(call.lowPriority)
        let everything = ([call.executable] + call.arguments + (call.environment ?? [:]).flatMap { [$0.key, $0.value] })
        #expect(!everything.contains { $0.contains("sudo") })
    }

    @Test("progress stays indeterminate: no progress events from brew")
    func noProgressEvents() async throws {
        let temp = try TempDirectory()
        let tools = FakeTools(["brew"])
        let runner = FakeRunner.replaying([.stdout("==> Downloading x"), .stdout("######## 50.0%")], status: 0,
                                          sideEffect: { tools.add(["clamscan", "freshclam"]) })
        let events = await collectEvents(installer(tools: tools, runner: runner, support: temp.url).install())
        let progressCount = events.filter { event in
            guard case .progress = event else { return false }
            return true
        }.count
        #expect(progressCount == 0)
    }

    @Test("failure: non-zero exit carries the stderr tail, sanitized and bounded")
    func installFailure() async throws {
        let temp = try TempDirectory()
        let runner = FakeRunner.replaying([
            .stderr("first line"), .stderr("Error: one"), .stderr("Error: two"),
            .stdout("Error: stdout reason"), .stderr("\u{1B}[31mError:\u{1B}[0m no space left\u{7}"),
            .stderr(String(repeating: "z", count: 3000))
        ], status: 1)
        let events = await collectEvents(
            installer(tools: FakeTools(["brew"]), runner: runner, support: temp.url).install()
        )
        guard case let .failed(message)? = events.last, events.count == 1 else {
            Issue.record("expected a single failure, got \(events)")
            return
        }
        #expect(message.hasPrefix("Homebrew failed (exit 1): "))
        #expect(!message.contains("first line"))
        #expect(!message.contains("one"))
        #expect(!message.contains("two"))
        #expect(message.contains("stdout reason"))
        #expect(message.contains("Error: no space left"))
        #expect(!message.contains("[31m"))
        #expect(!message.unicodeScalars.contains { $0.properties.generalCategory == .control })
        #expect(message.count < 500)
    }

    @Test("failure without stderr still reports the exit status")
    func failureWithoutStderr() async throws {
        let temp = try TempDirectory()
        let runner = FakeRunner.replaying([.stdout("==> Downloading x")], status: 7)
        let events = await collectEvents(
            installer(tools: FakeTools(["brew"]), runner: runner, support: temp.url).install()
        )
        #expect(events == [.stage("Downloading ClamAV…"), .failed(message: "Homebrew failed (exit 7)")])
    }

    @Test("exit 0 but ClamAV not found afterwards is a failure")
    func exitZeroNotInstalled() async throws {
        let temp = try TempDirectory()
        let runner = FakeRunner.replaying([.stdout("==> Summary")], status: 0)
        let events = await collectEvents(
            installer(tools: FakeTools(["brew"]), runner: runner, support: temp.url).install()
        )
        guard case .failed? = events.last else {
            Issue.record("expected failure, got \(events)")
            return
        }
        #expect(!events.contains(.finished))
    }

    // MARK: single flight and cancellation

    private func waitForCalls(_ runner: FakeRunner, _ count: Int) async {
        let deadline = Date().addingTimeInterval(10)
        while runner.recorded.count < count, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    @Test("a second concurrent call is refused, and a new one works after the first finished")
    func singleFlight() async throws {
        let temp = try TempDirectory()
        let tools = FakeTools(["brew", "freshclam"])
        let finishers = Mutex<[@Sendable (Int32) -> Void]>([])
        let runner = FakeRunner { _ in
            let (stream, source) = AsyncStream<ProcessLine>.makeStream()
            let (process, finish) = RunningProcess.controllable(lines: stream, onTerminate: { source.finish() })
            finishers.withLock { $0.append { status in
                source.finish()
                finish(status)
            } }
            return process
        }
        let sut = installer(tools: tools, runner: runner, support: temp.url)
        let first = sut.install()
        let refusedInstall = await collectEvents(sut.install())
        let refusedUpdate = await collectEvents(sut.updateDefinitions())
        let busy = InstallEvent.failed(message: "Another install or update is already running")
        #expect(refusedInstall == [busy])
        #expect(refusedUpdate == [busy])
        #expect(runner.recorded.count <= 1)

        await waitForCalls(runner, 1)
        let firstFinish = try #require(finishers.withLock { $0.first })
        firstFinish(1)
        let firstEvents = await collectEvents(first)
        #expect(firstEvents.count == 1)

        let second = sut.install()
        await waitForCalls(runner, 2)
        #expect(runner.recorded.count == 2)
        let last = try #require(finishers.withLock { $0.last })
        last(1)
        _ = await collectEvents(second)
    }

    @Test("cancelling the consumer terminates the brew process group")
    func cancellationTerminates() async throws {
        let temp = try TempDirectory()
        let signals = Mutex<[Bool]>([])
        let runner = FakeRunner { _ in
            let (stream, source) = AsyncStream<ProcessLine>.makeStream()
            let (process, _) = RunningProcess.controllable(lines: stream, onSignal: { _, group in
                signals.withLock { $0.append(group) }
                source.finish()
            })
            return process
        }
        let sut = installer(tools: FakeTools(["brew"]), runner: runner, support: temp.url)
        let stream = sut.install()
        let consumer = Task { await collectEvents(stream) }
        await waitForCalls(runner, 1)
        consumer.cancel()
        _ = await consumer.value
        let deadline = Date().addingTimeInterval(10)
        while signals.withLock({ $0.isEmpty }), Date() < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        let recorded = signals.withLock { $0 }
        #expect(!recorded.isEmpty)
        #expect(recorded.filter { $0 == false }.isEmpty, "the whole process group must be targeted")
    }

    // MARK: quit hook

    private func hangingRunner(signals: SignalLog) -> FakeRunner {
        FakeRunner { _ in
            let (stream, source) = AsyncStream<ProcessLine>.makeStream()
            let (process, _) = RunningProcess.controllable(lines: stream, onSignal: { signal, _ in
                signals.add(signal)
                source.finish()
            })
            return process
        }
    }

    @Test("terminateNow kills a running install, is idempotent, and frees the slot")
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
        let second = sut.install()
        await waitForCalls(runner, 2)
        #expect(runner.recorded.count == 2)
        sut.terminateNow()
        _ = await collectEvents(second)
    }

    @Test("terminateNow is a no-op when idle")
    func quitHookIdle() throws {
        let temp = try TempDirectory()
        let runner = FakeRunner.replaying([], status: 0)
        let sut = installer(tools: FakeTools(["brew"]), runner: runner, support: temp.url)
        sut.terminateNow()
        sut.terminateNow()
        #expect(runner.recorded.isEmpty)
    }
}
