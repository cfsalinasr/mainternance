import Darwin
import Dispatch
import Foundation

/// Runs executables with `Foundation.Process`: `executableURL` plus an argument array, never a shell.
///
/// - `environment` is merged over the current environment, so additions never wipe `PATH`.
/// - `lowPriority` sets `qualityOfService = .utility`; no extra niceness is applied.
/// - stdout and stderr are drained on separate dispatch threads, so output beyond the 64 KB pipe buffer cannot
///   deadlock the child. stdin is `/dev/null`.
/// - The runner is stateless; the returned `RunningProcess` owns the child (see its documentation for what
///   happens when it is dropped mid-run).
public struct SystemProcessRunner: ProcessRunning {
    public init() {}

    public func run(
        _ executable: String,
        arguments: [String],
        environment: [String: String]?,
        lowPriority: Bool
    ) -> RunningProcess {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let environment {
            process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
        }
        if lowPriority {
            process.qualityOfService = .utility
        }
        process.standardInput = FileHandle.nullDevice
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        var continuation: AsyncStream<ProcessLine>.Continuation!
        let stream = AsyncStream<ProcessLine>(bufferingPolicy: .unbounded) { continuation = $0 }
        let sink = continuation!
        let control = ProcessControl(process: process, exitStatus: nil)

        let group = DispatchGroup()
        group.enter() // exit
        process.terminationHandler = { finished in
            let signalled = finished.terminationReason == .uncaughtSignal
            control.finish(status: signalled ? 128 + finished.terminationStatus : finished.terminationStatus)
            group.leave()
        }
        do {
            try process.run()
        } catch {
            process.terminationHandler = nil
            let handles = [
                outPipe.fileHandleForReading, outPipe.fileHandleForWriting,
                errPipe.fileHandleForReading, errPipe.fileHandleForWriting
            ]
            for handle in handles {
                try? handle.close()
            }
            sink.yield(.stderr("Could not start \(executable): \(error.localizedDescription)"))
            sink.finish()
            control.finish(status: 127)
            return RunningProcess(lines: stream, processIdentifier: nil, control: control)
        }
        // The parent must close its copies of the write ends or the readers never see EOF.
        try? outPipe.fileHandleForWriting.close()
        try? errPipe.fileHandleForWriting.close()
        Self.drain(outPipe.fileHandleForReading, into: sink, group: group, tag: ProcessLine.stdout)
        Self.drain(errPipe.fileHandleForReading, into: sink, group: group, tag: ProcessLine.stderr)
        group.notify(queue: .global(qos: .utility)) { sink.finish() }
        return RunningProcess(lines: stream, processIdentifier: process.processIdentifier, control: control)
    }

    private static func drain(
        _ handle: FileHandle,
        into sink: AsyncStream<ProcessLine>.Continuation,
        group: DispatchGroup,
        tag: @escaping @Sendable (String) -> ProcessLine
    ) {
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            var splitter = LineSplitter()
            var buffer = [UInt8](repeating: 0, count: 64 * 1024)
            let descriptor = handle.fileDescriptor
            while true {
                let count = buffer.withUnsafeMutableBytes { read(descriptor, $0.baseAddress, $0.count) }
                if count > 0 {
                    let lines = buffer.withUnsafeBufferPointer {
                        splitter.append(UnsafeBufferPointer(rebasing: $0[0 ..< count]))
                    }
                    for line in lines {
                        sink.yield(tag(line))
                    }
                } else if count < 0, errno == EINTR {
                    continue
                } else {
                    break
                }
            }
            if let last = splitter.flush() {
                sink.yield(tag(last))
            }
            try? handle.close()
            group.leave()
        }
    }
}
