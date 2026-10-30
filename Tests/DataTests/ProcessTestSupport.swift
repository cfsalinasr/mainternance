import Darwin
import Foundation
@testable import MainternanceData
import Synchronization
import Testing

/// A temp directory with fixture scripts. `/bin/sh` appears ONLY inside these fixtures; production never uses it.
/// Every fixture is time-bounded (at most about 20 s), and on deinit (also when an expectation failed or a
/// `#require` threw) the fixture kills every process it started and removes its directory.
final class Fixture {
    let directory: URL
    private let started = Mutex<[RunningProcess]>([])

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mainternance-runner-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    deinit {
        for process in started.withLock({ $0 }) {
            process.terminateNow()
        }
        try? FileManager.default.removeItem(at: directory)
    }

    func script(_ body: String, name: String = "tool.sh") throws -> String {
        let url = directory.appendingPathComponent(name)
        try ("#!/bin/sh\n" + body + "\n").write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url.path
    }

    func start(_ path: String, _ arguments: [String] = [], env: [String: String]? = nil) -> RunningProcess {
        let process = SystemProcessRunner().run(path, arguments: arguments, environment: env, lowPriority: false)
        started.withLock { $0.append(process) }
        return process
    }

    /// A fixture that stays alive for at most 20 s: prints `ready` after a background grandchild started.
    func lingeringScript() throws -> String {
        try script("/bin/sleep 20 &\necho \"gc $!\"\necho ready\nwait")
    }
}

struct Outcome: Sendable {
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

let runner = SystemProcessRunner()

func start(_ path: String, _ arguments: [String] = [], env: [String: String]? = nil) -> RunningProcess {
    runner.run(path, arguments: arguments, environment: env, lowPriority: false)
}

func collect(_ process: RunningProcess) async -> Outcome {
    async let status = process.wait()
    var lines: [ProcessLine] = []
    for await line in process.lines {
        lines.append(line)
    }
    return await Outcome(lines: lines, status: status)
}

/// First-wins hand-off between the operation and the timer.
final class Race<T: Sendable>: Sendable {
    private let continuation: Mutex<CheckedContinuation<T?, Never>?>

    init(_ continuation: CheckedContinuation<T?, Never>) {
        self.continuation = Mutex(continuation)
    }

    func resolve(_ value: T?) {
        let taken = continuation.withLock { current -> CheckedContinuation<T?, Never>? in
            defer { current = nil }
            return current
        }
        taken?.resume(returning: value)
    }
}

/// Runs `operation`; when it takes longer than `seconds` this FAILS the test with a clear message and returns nil
/// WITHOUT waiting for the operation (it is abandoned; the fixture's deinit kills any child it was waiting on).
func within<T: Sendable>(
    _ seconds: Double,
    _ what: String,
    _ operation: @escaping @Sendable () async -> T
) async -> T? {
    let result: T? = await withCheckedContinuation { (continuation: CheckedContinuation<T?, Never>) in
        let race = Race(continuation)
        let timer = Task {
            do { try await Task.sleep(for: .seconds(seconds)) } catch { return }
            race.resolve(nil)
        }
        Task {
            await race.resolve(operation())
            timer.cancel()
        }
    }
    if result == nil {
        Issue.record("Timed out after \(seconds)s: \(what)")
    }
    return result
}

struct Terminated: Sendable {
    var status: Int32
    var elapsed: TimeInterval
    var wasRunning: Bool
}

func isGone(_ pid: Int32) -> Bool {
    kill(pid, 0) == -1 && errno == ESRCH
}

/// Polls (bounded) until `pid` no longer exists; a reparented grandchild needs a moment to be reaped.
func waitUntilGone(_ pid: Int32, timeout: Double = 5) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while !isGone(pid), Date() < deadline {
        try? await Task.sleep(for: .milliseconds(20))
    }
    return isGone(pid)
}

/// Reads lines until `ready`; returns the grandchild pid announced as `gc <pid>`.
func awaitReady(_ process: RunningProcess) async -> Int32? {
    var iterator = process.lines.makeAsyncIterator()
    var grandchild: Int32?
    while let line = await iterator.next() {
        if case let .stdout(text) = line {
            if text.hasPrefix("gc ") {
                grandchild = Int32(text.dropFirst(3))
            }
            if text == "ready" {
                return grandchild ?? 0
            }
        }
    }
    return nil
}
