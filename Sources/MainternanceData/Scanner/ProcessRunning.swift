import Darwin
import Dispatch
import Foundation
import Synchronization

/// One line of child output, tagged with the stream it came from.
public enum ProcessLine: Equatable, Sendable {
    case stdout(String)
    case stderr(String)
}

/// Starts external executables. Implementations never use a shell: the executable and its arguments are separate.
public protocol ProcessRunning: Sendable {
    /// Starts `executable` (an absolute path) with `arguments` passed verbatim.
    /// `environment`, when non-nil, is merged over the current environment.
    func run(
        _ executable: String,
        arguments: [String],
        environment: [String: String]?,
        lowPriority: Bool
    ) -> RunningProcess
}

/// Splits raw bytes into lines on `\n` (a trailing `\r` is dropped). Invalid UTF-8 becomes U+FFFD, no byte is lost.
struct LineSplitter {
    private var buffer: [UInt8] = []

    mutating func append(_ bytes: UnsafeBufferPointer<UInt8>) -> [String] {
        buffer.append(contentsOf: bytes)
        var lines: [String] = []
        var start = 0
        for index in buffer.indices where buffer[index] == 0x0A {
            lines.append(Self.decode(buffer[start ..< index]))
            start = index + 1
        }
        if start > 0 {
            buffer.removeSubrange(0 ..< start)
        }
        return lines
    }

    /// The final partial line (no trailing newline), if any.
    mutating func flush() -> String? {
        guard !buffer.isEmpty else { return nil }
        defer { buffer.removeAll() }
        return Self.decode(buffer[...])
    }

    private static func decode(_ bytes: ArraySlice<UInt8>) -> String {
        var slice = bytes
        if slice.last == 0x0D {
            slice = slice.dropLast()
        }
        // Not Data -> String?: lossy decoding is intended (invalid bytes become U+FFFD).
        return String(decoding: slice, as: UTF8.self) // swiftlint:disable:this optional_data_string_conversion
    }
}

/// Thread-safe control block of one child process: exit status, waiters and signalling.
final class ProcessControl: Sendable {
    private struct State {
        var process: Process?
        var exitStatus: Int32?
        var waiters: [CheckedContinuation<Int32, Never>] = []
        var terminating = false
    }

    private let state: Mutex<State>

    init(process: Process?, exitStatus: Int32?) {
        state = Mutex(State(process: process, exitStatus: exitStatus))
    }

    var isRunning: Bool {
        state.withLock { $0.exitStatus == nil && $0.process != nil }
    }

    /// Records the exit status (first call wins) and wakes every waiter.
    func finish(status: Int32) {
        let waiters = state.withLock { current -> [CheckedContinuation<Int32, Never>] in
            guard current.exitStatus == nil else { return [] }
            current.exitStatus = status
            current.process = nil
            defer { current.waiters = [] }
            return current.waiters
        }
        for waiter in waiters {
            waiter.resume(returning: status)
        }
    }

    /// Waits for exit. Cancelling the waiting task terminates the child.
    func wait() async -> Int32 {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let known = state.withLock { current -> Int32? in
                    if let status = current.exitStatus {
                        return status
                    }
                    current.waiters.append(continuation)
                    return nil
                }
                if let known {
                    continuation.resume(returning: known)
                }
            }
        } onCancel: {
            requestTermination()
        }
    }

    /// Sends SIGTERM once and schedules a SIGKILL two seconds later if the child is still there.
    func requestTermination() {
        let shouldEscalate = state.withLock { current -> Bool in
            guard current.exitStatus == nil, !current.terminating, let process = current.process else { return false }
            current.terminating = true
            process.terminate()
            return true
        }
        guard shouldEscalate else { return }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2) { [self] in kill(signal: SIGKILL) }
    }

    /// Immediate SIGKILL when the child is still running (used when the handle is dropped).
    func kill(signal: Int32) {
        state.withLock { current in
            guard current.exitStatus == nil, let process = current.process, process.isRunning else { return }
            // Read the pid only now: it is 0 until the process has been launched, and kill(0, ...) would signal
            // our whole process group.
            let pid = process.processIdentifier
            guard pid > 0 else { return }
            Darwin.kill(pid, signal)
        }
    }
}

/// A started child process: its output lines, exit status and termination.
///
/// Dropping the last reference to a `RunningProcess` that is still running kills the child (SIGKILL), so a
/// discarded handle can never leave an orphan. Keep the handle alive for as long as the child should run.
public final class RunningProcess: Sendable {
    /// Output lines of both streams; each stream keeps its own order. Finishes after the child exited and both
    /// pipes are drained. A grandchild that inherited a pipe and outlives the child delays the end of the stream.
    public let lines: AsyncStream<ProcessLine>
    /// The child's pid, nil when it could not be launched.
    public let processIdentifier: Int32?
    private let control: ProcessControl

    init(lines: AsyncStream<ProcessLine>, processIdentifier: Int32?, control: ProcessControl) {
        self.lines = lines
        self.processIdentifier = processIdentifier
        self.control = control
    }

    /// An already finished process with scripted output; handy for fake runners in tests.
    public static func finished(lines: [ProcessLine], status: Int32) -> RunningProcess {
        let stream = AsyncStream<ProcessLine> { continuation in
            for line in lines {
                continuation.yield(line)
            }
            continuation.finish()
        }
        return RunningProcess(
            lines: stream,
            processIdentifier: nil,
            control: ProcessControl(process: nil, exitStatus: status)
        )
    }

    deinit { control.kill(signal: SIGKILL) }

    public var isRunning: Bool {
        control.isRunning
    }

    /// The exit status; 127 when the launch failed; `128 + signal` when a signal ended the child.
    public func wait() async -> Int32 {
        await control.wait()
    }

    /// SIGTERM, then SIGKILL after 2 seconds, and returns once the child is gone and reaped.
    /// A no-op when the child already exited; calling it more than once is safe.
    public func terminate() async {
        control.requestTermination()
        _ = await control.wait()
    }
}
