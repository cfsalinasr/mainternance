import Foundation
@testable import MainternanceData
import MainternanceDomain
import Synchronization

/// One recorded `ProcessRunning.run` call.
struct RunCall: Sendable, Equatable {
    var executable: String
    var arguments: [String]
    var environment: [String: String]?
    var lowPriority: Bool
}

/// Fake runner: records every call and lets the test decide what the "process" does.
final class FakeRunner: ProcessRunning {
    private let calls = Mutex<[RunCall]>([])
    private let handler: @Sendable (RunCall) -> RunningProcess

    init(_ handler: @escaping @Sendable (RunCall) -> RunningProcess) {
        self.handler = handler
    }

    /// A runner whose process replays `lines`, runs `sideEffect`, and exits with `status`.
    static func replaying(
        _ lines: [ProcessLine],
        status: Int32,
        sideEffect: @escaping @Sendable () -> Void = { /* no side effect */ }
    ) -> FakeRunner {
        FakeRunner { _ in
            sideEffect()
            return RunningProcess.finished(lines: lines, status: status)
        }
    }

    var recorded: [RunCall] {
        calls.withLock { $0 }
    }

    func run(
        _ executable: String,
        arguments: [String],
        environment: [String: String]?,
        lowPriority: Bool
    ) -> RunningProcess {
        let call = RunCall(
            executable: executable, arguments: arguments, environment: environment, lowPriority: lowPriority
        )
        calls.withLock { $0.append(call) }
        return handler(call)
    }
}

/// A locator over a mutable set of "installed" tool names, so a test can flip them on mid-run.
final class FakeTools: Sendable {
    private let present: Mutex<Set<String>>

    init(_ names: Set<String>) {
        present = Mutex(names)
    }

    func add(_ names: Set<String>) {
        present.withLock { $0.formUnion(names) }
    }

    var locator: ToolLocator {
        ToolLocator(candidates: ["/fake/bin"], isExecutable: { [self] path in
            present.withLock { $0.contains(String(path.dropFirst("/fake/bin/".count))) }
        })
    }
}

/// A unique temp directory removed on deinit.
final class TempDirectory {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mainternance-clamav-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }

    var names: [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []).sorted()
    }
}

func collectEvents(_ stream: AsyncStream<InstallEvent>) async -> [InstallEvent] {
    var events: [InstallEvent] = []
    for await event in stream {
        events.append(event)
    }
    return events
}

func permissions(_ url: URL) -> Int? {
    (try? FileManager.default.attributesOfItem(atPath: url.path))?[.posixPermissions] as? Int
}
