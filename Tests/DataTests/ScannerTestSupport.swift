import Foundation
@testable import MainternanceData
import MainternanceDomain
import Synchronization

/// A clock that moves only when the test says so, or by a fixed step on every read.
final class TestClock: Sendable {
    private let value: Mutex<Date>
    private let step: TimeInterval

    init(_ start: Date = Date(timeIntervalSince1970: 1_800_000_000), step: TimeInterval = 0) {
        value = Mutex(start)
        self.step = step
    }

    func now() -> Date {
        value.withLock { current in
            defer { current = current.addingTimeInterval(step) }
            return current
        }
    }

    var reading: @Sendable () -> Date {
        { [self] in now() }
    }
}

/// A fake `clamscan` that stays running until the test finishes it or the scanner signals it.
final class ControlledScan: Sendable {
    private let continuation: AsyncStream<ProcessLine>.Continuation
    private let stream: AsyncStream<ProcessLine>
    private struct Exit {
        var finish: (@Sendable (Int32) -> Void)?
        var pending: Int32?
    }

    private let exitState = Mutex(Exit())
    private let signalLog = Mutex<[(signal: Int32, group: Bool)]>([])
    private let launches = Mutex(0)
    private let root = Mutex<String?>(nil)

    init() {
        (stream, continuation) = AsyncStream.makeStream(of: ProcessLine.self)
    }

    /// The runner handler: only the first call gets the controllable process.
    func launch() -> RunningProcess {
        launches.withLock { $0 += 1 }
        let cont = continuation
        let made = RunningProcess.controllable(lines: stream, onSignal: { [self] signal, group in
            signalLog.withLock { $0.append((signal, group)) }
            cont.finish()
        })
        let early = exitState.withLock { current -> Int32? in
            current.finish = made.finish
            return current.pending
        }
        if let early {
            made.finish(early)
        }
        return made.process
    }

    /// Lines written as `/t/...` are rewritten to live under the scan root of the fixture.
    func mapRoot(_ path: String) {
        root.withLock { $0 = path }
    }

    private func mapped(_ line: String) -> String {
        guard let prefix = root.withLock({ $0 }) else { return line }
        return line.replacingOccurrences(of: "/t/", with: prefix + "/")
    }

    func send(_ lines: [String]) {
        for line in lines {
            continuation.yield(.stdout(mapped(line)))
        }
    }

    func sendError(_ line: String) {
        continuation.yield(.stderr(mapped(line)))
    }

    /// The child exits by itself with `status` (also when called before the scanner launched it).
    func exit(_ status: Int32) {
        let finish = exitState.withLock { current -> (@Sendable (Int32) -> Void)? in
            current.pending = status
            return current.finish
        }
        finish?(status)
        continuation.finish()
    }

    var launchCount: Int {
        launches.withLock { $0 }
    }

    var signals: [(signal: Int32, group: Bool)] {
        signalLog.withLock { $0 }
    }
}

/// Everything a scanner test needs: temp support dir with a definitions file, tools, and a scanner.
struct ScannerFixture {
    let temp: TempDirectory
    let paths: ClamAVPaths
    let tools: FakeTools
    let clock: TestClock
    let runner: FakeRunner
    let scanner: ClamAVScanner
    /// A folder to scan (custom scope).
    let target: URL

    init(
        tools names: Set<String> = ["brew", "clamscan", "freshclam"],
        definitionsAge: TimeInterval? = 3600,
        clock: TestClock = TestClock(),
        temp existing: TempDirectory? = nil,
        runner: FakeRunner
    ) throws {
        temp = try existing ?? TempDirectory()
        paths = ClamAVPaths(supportDirectory: temp.url.appendingPathComponent("support"))
        tools = FakeTools(names)
        self.clock = clock
        self.runner = runner
        target = temp.url.appendingPathComponent("target", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        if let definitionsAge {
            try FileManager.default.createDirectory(at: paths.databaseDirectory, withIntermediateDirectories: true)
            let file = paths.databaseDirectory.appendingPathComponent("daily.cvd")
            try Data("x".utf8).write(to: file)
            try FileManager.default.setAttributes(
                [.modificationDate: clock.now().addingTimeInterval(-definitionsAge)], ofItemAtPath: file.path
            )
        }
        let installer = ClamAVInstaller(locator: tools.locator, runner: runner, paths: paths)
        scanner = ClamAVScanner(
            locator: tools.locator, runner: runner, paths: paths,
            definitions: DefinitionsStore(paths: paths), installer: installer,
            now: clock.reading, home: temp.url
        )
    }

    /// The scan root of `target` exactly as the scanner computes it.
    var root: String {
        ScanScopes.roots(for: .custom(target), home: temp.url, exists: { _ in true }).first ?? ""
    }

    /// `relative` below the scan root.
    func path(_ relative: String) -> String {
        root + "/" + relative
    }

    /// A fixture whose runner replays `lines` and exits with `status`. Paths written as `/t/...` are rewritten
    /// to live under the scan root.
    static func replaying(
        _ lines: [ProcessLine], status: Int32, clock: TestClock = TestClock()
    ) throws -> ScannerFixture {
        let temp = try TempDirectory()
        let target = temp.url.appendingPathComponent("target", isDirectory: true)
        let root = ScanScopes.roots(for: .custom(target), home: temp.url, exists: { _ in true }).first ?? ""
        let mapped = lines.map { line -> ProcessLine in
            switch line {
            case let .stdout(text): .stdout(text.replacingOccurrences(of: "/t/", with: root + "/"))
            case let .stderr(text): .stderr(text.replacingOccurrences(of: "/t/", with: root + "/"))
            }
        }
        return try ScannerFixture(clock: clock, temp: temp, runner: FakeRunner.replaying(mapped, status: status))
    }

    func run(_ scope: ScanScope? = nil) async -> [ScanEvent] {
        var events: [ScanEvent] = []
        for await event in scanner.scan(scope ?? .custom(target)) {
            events.append(event)
        }
        return events
    }
}

extension ScanEvent {
    var isFound: Bool {
        guard case .found = self else { return false }
        return true
    }

    var isProgress: Bool {
        guard case .progress = self else { return false }
        return true
    }

    var isFailure: Bool {
        guard case .failed = self else { return false }
        return true
    }
}

extension [ScanEvent] {
    var findings: [ScanFinding] {
        compactMap {
            if case let .found(finding) = $0 {
                finding
            } else {
                nil
            }
        }
    }

    var progressCounts: [Int] {
        compactMap {
            if case let .progress(scanned, _) = $0 {
                scanned
            } else {
                nil
            }
        }
    }

    var summary: ScanSummary? {
        for event in self {
            if case let .finished(summary) = event {
                return summary
            }
        }
        return nil
    }

    var failure: String? {
        for event in self {
            if case let .failed(message) = event {
                return message
            }
        }
        return nil
    }
}

func okLines(_ count: Int, prefix: String = "/t/f") -> [ProcessLine] {
    (0 ..< count).map { .stdout("\(prefix)\($0): OK") }
}

/// Polls until `condition` holds (bounded; used only to await another task's side effect).
func eventually(_ seconds: Double = 10, _ condition: @Sendable () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        if condition() {
            return true
        }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return condition()
}
