import Foundation

/// Runs `/bin/launchctl` through a `ProcessRunning` with an argument array (never a shell), collects its output and
/// stops it when it takes longer than `timeout`.
struct LaunchctlCommand: Sendable {
    /// The fixed macOS location; nothing on `PATH` is ever used.
    static let executable = "/bin/launchctl"
    /// A reason shown to the owner is cut to this many characters.
    static let maxReasonLength = 300
    /// More output than this is not kept (nothing launchctl prints for us comes close).
    static let maxLines = 100_000

    struct Output: Sendable, Equatable {
        var status: Int32
        var stdout: [String]
        var stderr: [String]
    }

    let runner: any ProcessRunning
    let timeout: Duration

    /// A launchctl that does not end within `timeout` is terminated (its status then is not 0).
    func run(_ arguments: [String]) async -> Output {
        let process = runner.run(Self.executable, arguments: arguments, environment: nil, lowPriority: false)
        let limit = timeout
        let watchdog = Task {
            do { try await Task.sleep(for: limit) } catch { return }
            await process.terminate()
        }
        defer { watchdog.cancel() }
        var output = Output(status: 0, stdout: [], stderr: [])
        var kept = 0
        for await line in process.lines where kept < Self.maxLines {
            kept += 1
            switch line {
            case let .stdout(text): output.stdout.append(text)
            case let .stderr(text): output.stderr.append(text)
            }
        }
        output.status = await process.wait()
        return output
    }

    /// The last non-empty line launchctl wrote to stderr (or else stdout), shortened; or the exit status.
    static func reason(_ output: Output) -> String {
        let trimmed = { (lines: [String]) in
            lines.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.last { !$0.isEmpty }
        }
        guard let line = trimmed(output.stderr) ?? trimmed(output.stdout) else {
            return "launchctl ended with status \(output.status)."
        }
        return line.count > maxReasonLength ? String(line.prefix(maxReasonLength)) + "…" : line
    }
}
