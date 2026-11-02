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
///
/// Only newly appended bytes are scanned. A single line is capped at `maxLineBytes`: a longer line is emitted in
/// pieces of that size, the remainder continuing as the next line (a multi-byte character cut at the boundary
/// decodes to replacement characters).
struct LineSplitter {
    static let maxLineBytes = 1 << 20

    private var buffer: [UInt8] = []
    private var scanned = 0

    mutating func append(_ bytes: UnsafeBufferPointer<UInt8>) -> [String] {
        buffer.append(contentsOf: bytes)
        var lines: [String] = []
        var start = 0
        var index = scanned
        while index < buffer.count {
            if buffer[index] == 0x0A {
                lines.append(Self.decode(buffer[start ..< index], trimCarriageReturn: true))
                start = index + 1
            } else if index - start == Self.maxLineBytes {
                lines.append(Self.decode(buffer[start ..< index], trimCarriageReturn: false))
                start = index
            }
            index += 1
        }
        if start > 0 {
            buffer.removeSubrange(0 ..< start)
        }
        scanned = buffer.count
        return lines
    }

    /// The final partial line (no trailing newline), if any.
    mutating func flush() -> String? {
        guard !buffer.isEmpty else { return nil }
        defer {
            buffer.removeAll()
            scanned = 0
        }
        return Self.decode(buffer[...], trimCarriageReturn: true)
    }

    private static func decode(_ bytes: ArraySlice<UInt8>, trimCarriageReturn: Bool) -> String {
        var slice = bytes
        if trimCarriageReturn, slice.last == 0x0D {
            slice = slice.dropLast()
        }
        // Lossy decoding is intended: invalid bytes become U+FFFD.
        return String(decoding: slice, as: UTF8.self) // swiftlint:disable:this optional_data_string_conversion
    }
}

/// Thread-safe control block of one child process: exit status, waiters and signalling.
///
/// Signals go through `kill(2)` while the lock is held, so a signal can never be sent after `finish` recorded the
/// exit (no late SIGKILL at a recycled pid). No Foundation `Process` method is called while holding the lock.
final class ProcessControl: Sendable {
    /// Replaces real signalling (fakes): receives the control, the signal and whether it targets the whole group.
    typealias Hook = @Sendable (ProcessControl, Int32, Bool) -> Void

    private struct State {
        var keepAlive: Process? // only retained, never called
        var pid: Int32 = 0
        var exitStatus: Int32?
        var waiters: [CheckedContinuation<Int32, Never>] = []
        var terminating = false
    }

    private let state: Mutex<State>
    private let hook: Hook?

    init(exitStatus: Int32? = nil, hook: Hook? = nil) {
        state = Mutex(State(exitStatus: exitStatus))
        self.hook = hook
    }

    var isRunning: Bool {
        state.withLock { $0.exitStatus == nil }
    }

    /// Records the launched child. Ignored when it already exited.
    func start(pid: Int32, process: Process) {
        state.withLock { current in
            guard current.exitStatus == nil else { return }
            current.pid = pid
            current.keepAlive = process
        }
    }

    /// Records the exit status (first call wins) and wakes every waiter.
    func finish(status: Int32) {
        let waiters = state.withLock { current -> [CheckedContinuation<Int32, Never>] in
            guard current.exitStatus == nil else { return [] }
            current.exitStatus = status
            current.keepAlive = nil
            defer { current.waiters = [] }
            return current.waiters
        }
        for waiter in waiters {
            waiter.resume(returning: status)
        }
    }

    /// Waits for exit. Cancelling the waiting task terminates the child (and its group).
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
            requestTermination(group: true)
        }
    }

    /// Sends SIGTERM once and schedules a SIGKILL two seconds later if the child is still there.
    func requestTermination(group: Bool) {
        let first = state.withLock { current -> Bool in
            guard current.exitStatus == nil, !current.terminating else { return false }
            current.terminating = true
            return true
        }
        guard first, signalIfRunning(SIGTERM, group: group) else { return }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2) { [self] in
            _ = signalIfRunning(SIGKILL, group: group)
        }
    }

    /// Immediate SIGKILL to the child's whole group; synchronous and idempotent.
    func killNow() {
        _ = signalIfRunning(SIGKILL, group: true)
    }

    /// Signals the child when it has not exited. With `group`, signals its whole process group, but only when the
    /// child is that group's leader (so our own group is never hit). Never signals pid 0, -1 or negative values.
    @discardableResult
    private func signalIfRunning(_ signal: Int32, group: Bool) -> Bool {
        if let hook {
            guard isRunning else { return false }
            hook(self, signal, group)
            return true
        }
        return state.withLock { current in
            guard current.exitStatus == nil, current.pid > 1 else { return false }
            let leads = group && getpgid(current.pid) == current.pid
            Darwin.kill(leads ? -current.pid : current.pid, signal)
            return true
        }
    }
}

/// A started child process: its output lines, exit status and termination.
///
/// Dropping the last reference to a `RunningProcess` that is still running kills the child's whole process group
/// (SIGKILL), so a discarded handle can never leave an orphan. Keep the handle alive for as long as the child
/// should run.
public final class RunningProcess: Sendable {
    /// Output lines of both streams; each stream keeps its own order. Supports a SINGLE consumer (it is an
    /// `AsyncStream`). Finishes after the child exited and both pipes are drained. A grandchild that inherited a
    /// pipe and outlives the child delays the end of the stream (terminating the group avoids that).
    public let lines: AsyncStream<ProcessLine>
    /// The child's pid, nil when it could not be launched.
    public let processIdentifier: Int32?
    private let control: ProcessControl

    init(lines: AsyncStream<ProcessLine>, processIdentifier: Int32?, control: ProcessControl) {
        self.lines = lines
        self.processIdentifier = processIdentifier
        self.control = control
    }

    /// An already finished process with scripted output, for fake runners in tests.
    static func finished(lines: [ProcessLine], status: Int32) -> RunningProcess {
        let stream = AsyncStream<ProcessLine> { continuation in
            for line in lines {
                continuation.yield(line)
            }
            continuation.finish()
        }
        return RunningProcess(lines: stream, processIdentifier: nil, control: ProcessControl(exitStatus: status))
    }

    /// A fake that stays running until `finish(status)` is called (first call wins) or it is terminated.
    /// `terminate()` / `terminateNow()` call `onTerminate` and complete it with a signal-style status
    /// (143 for SIGTERM, 137 for SIGKILL). Finishing `lines` is up to the caller.
    static func controllable(
        lines: AsyncStream<ProcessLine>,
        onTerminate: @escaping @Sendable () -> Void
    ) -> (process: RunningProcess, finish: @Sendable (Int32) -> Void) {
        controllable(lines: lines, onSignal: { _, _ in onTerminate() })
    }

    /// Like the `onTerminate` variant, but reports the signal and whether the whole process group was targeted.
    static func controllable(
        lines: AsyncStream<ProcessLine>,
        onSignal: @escaping @Sendable (_ signal: Int32, _ group: Bool) -> Void
    ) -> (process: RunningProcess, finish: @Sendable (Int32) -> Void) {
        let control = ProcessControl(hook: { control, signal, group in
            onSignal(signal, group)
            control.finish(status: 128 + signal)
        })
        let process = RunningProcess(lines: lines, processIdentifier: nil, control: control)
        return (process, { control.finish(status: $0) })
    }

    deinit { control.killNow() }

    public var isRunning: Bool {
        control.isRunning
    }

    /// The exit status; 127 when the launch failed; `128 + signal` when a signal ended the child.
    public func wait() async -> Int32 {
        await control.wait()
    }

    /// SIGTERM, then SIGKILL after 2 seconds, and returns once the child is gone and reaped.
    /// With `killGroup` (the default) the signals go to the child's whole process group, so helpers it spawned
    /// (for example brew's curl, tar and git) die with it. A no-op when the child already exited; calling it
    /// more than once is safe.
    public func terminate(killGroup: Bool = true) async {
        control.requestTermination(group: killGroup)
        _ = await control.wait()
    }

    /// Synchronous, idempotent SIGKILL of the child's whole process group, without awaiting anything. Safe to call
    /// from `applicationWillTerminate`. A no-op once the child exited.
    /// Task 5/7: the owner of a running scan or install MUST call this on app quit, otherwise the child outlives
    /// the app.
    public func terminateNow() {
        control.killNow()
    }
}
