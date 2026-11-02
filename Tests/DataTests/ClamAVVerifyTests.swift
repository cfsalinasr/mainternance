import Foundation
@testable import MainternanceData
import MainternanceDomain
import Testing

@Suite("ClamAV verify finding")
struct ClamAVVerifyTests {
    /// The real runner splits child output on newlines, so a file name with a newline becomes several lines.
    private static func splitLines(_ lines: [ProcessLine]) -> [ProcessLine] {
        lines.flatMap { line -> [ProcessLine] in
            switch line {
            case let .stdout(text): text.components(separatedBy: "\n").map { .stdout($0) }
            case let .stderr(text): text.components(separatedBy: "\n").map { .stderr($0) }
            }
        }
    }

    private typealias Prepared = (fixture: ScannerFixture, path: String)

    private func replaying(
        _ build: (String) -> [ProcessLine], status: Int32, file: String = "sample file.exe"
    ) throws -> Prepared {
        let target = try TempDirectory()
        let path = target.url.appendingPathComponent("target").appendingPathComponent(file).path
        let fixture = try ScannerFixture(
            temp: target,
            runner: FakeRunner.replaying(Self.splitLines(build(path)), status: status)
        )
        try Data("x".utf8).write(to: URL(fileURLWithPath: path))
        return (fixture, path)
    }

    @Test("confirmed: a FOUND line for exactly that path, with the exact argv")
    func confirmed() async throws {
        let (fixture, path) = try replaying(
            { [.stdout("Scanning \($0)"), .stdout("\($0): Win.Test.EICAR_HDB-1 FOUND")] },
            status: 1
        )
        #expect(await fixture.scanner.verifyFinding(path: path) == .confirmed(signature: "Win.Test.EICAR_HDB-1"))
        let call = try #require(fixture.runner.recorded.first)
        #expect(call.executable == "/fake/bin/clamscan")
        #expect(call.arguments == [
            "--database=\(fixture.paths.databaseDirectory.path)", "-v", "--no-summary", "--", path
        ])
        #expect(call.lowPriority)
        #expect(fixture.runner.recorded.count == 1)
    }

    @Test("clean: an OK line and exit 0")
    func clean() async throws {
        let (fixture, path) = try replaying({ [.stdout("\($0): OK")] }, status: 0)
        #expect(await fixture.scanner.verifyFinding(path: path) == .clean)
    }

    @Test("no verdict, a verdict for another path, or an error exit is a failure")
    func failures() async throws {
        let silent = try replaying({ _ in [] }, status: 0)
        guard case .failed = await silent.fixture.scanner.verifyFinding(path: silent.path) else {
            Issue.record("expected failure without a verdict")
            return
        }
        let other = try replaying({ [.stdout("\($0)x: Sig FOUND")] }, status: 1)
        guard case .failed = await other.fixture.scanner.verifyFinding(path: other.path) else {
            Issue.record("expected failure for another path")
            return
        }
        let broken = try replaying({ _ in [.stderr("ERROR: Can't initialize antivirus engine")] }, status: 2)
        let result = await broken.fixture.scanner.verifyFinding(path: broken.path)
        guard case let .failed(message) = result else {
            Issue.record("expected failure on exit 2")
            return
        }
        #expect(message.contains("exit 2"))
        #expect(message.contains("antivirus engine"))
    }

    @Test("a clean line with a failing exit is not clean")
    func cleanNeedsExitZero() async throws {
        let (fixture, path) = try replaying({ [.stdout("\($0): OK")] }, status: 2)
        guard case .failed = await fixture.scanner.verifyFinding(path: path) else {
            Issue.record("expected failure")
            return
        }
    }

    @Test("hostile file names are passed verbatim after --", arguments: [
        "sp ace.exe", "-rf $(x) ; y", "it's \"q\".exe", "-- --infected", "line\nbreak.exe"
    ])
    func hostile(name: String) async throws {
        let (fixture, path) = try replaying({ [.stdout("\($0): Sig FOUND")] }, status: 1, file: name)
        let result = await fixture.scanner.verifyFinding(path: path)
        let call = try #require(fixture.runner.recorded.first)
        #expect(Array(call.arguments.suffix(2)) == ["--", path])
        if name.contains("\n") {
            // A path with a newline can never match a one-line verdict.
            guard case .failed = result else {
                Issue.record("a newline path must not be confirmed")
                return
            }
        } else {
            #expect(result == .confirmed(signature: "Sig"))
        }
    }

    @Test("directories, symlinks, missing files and relative paths are rejected without a process")
    func rejected() async throws {
        let (fixture, path) = try replaying({ [.stdout("\($0): Sig FOUND")] }, status: 1)
        let directory = fixture.target.path
        let link = fixture.target.appendingPathComponent("link").path
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: path)
        for bad in [directory, link, path + ".missing", "relative/file", "", "/a/../b", "/"] {
            guard case .failed = await fixture.scanner.verifyFinding(path: bad) else {
                Issue.record("expected rejection of \(bad)")
                continue
            }
        }
        #expect(fixture.runner.recorded.isEmpty)
    }

    @Test("refused when the engine is not ready")
    func notReady() async throws {
        let temp = try TempDirectory()
        let fixture = try ScannerFixture(
            definitionsAge: nil, temp: temp, runner: FakeRunner.replaying([], status: 0)
        )
        let file = fixture.target.appendingPathComponent("a.exe")
        try Data("x".utf8).write(to: file)
        guard case let .failed(message) = await fixture.scanner.verifyFinding(path: file.path) else {
            Issue.record("expected refusal")
            return
        }
        #expect(message.hasPrefix("Scanning engine is not ready: "))
        #expect(fixture.runner.recorded.isEmpty)
    }

    @Test("refused while a scan runs, the scan still completes, and the slot is free afterwards")
    func busy() async throws {
        let scan = ControlledScan()
        let fixture = try ScannerFixture(runner: FakeRunner { _ in scan.launch() })
        let file = fixture.target.appendingPathComponent("a.exe")
        try Data("x".utf8).write(to: file)
        scan.mapRoot(fixture.root)
        let scanner = fixture.scanner
        let target = fixture.target
        let path = file.path
        let outcome = await within(20, "busy verify") {
            var iterator = scanner.scan(.custom(target)).makeAsyncIterator()
            _ = await iterator.next()
            let refused = await scanner.verifyFinding(path: path)
            scan.send(["/t/a.exe: OK"])
            scan.exit(0)
            var events: [ScanEvent] = []
            while let event = await iterator.next() {
                events.append(event)
            }
            return (refused, events)
        }
        let (refused, events) = try #require(outcome)
        #expect(refused == .failed(message: "A scan is already running"))
        #expect(scan.launchCount == 1)
        #expect(events.summary?.scanned == 1)
        // The slot is free again for a verification.
        let again = ControlledScan()
        again.exit(0)
        #expect(await scanner.verifyFinding(path: path) != .failed(message: "A scan is already running"))
    }

    @Test("a verification holds the slot: a scan started meanwhile is refused; cancelScan stops it")
    func verifyBlocksScanAndCancels() async throws {
        let scan = ControlledScan()
        let fixture = try ScannerFixture(runner: FakeRunner { _ in scan.launch() })
        let file = fixture.target.appendingPathComponent("a.exe")
        try Data("x".utf8).write(to: file)
        let scanner = fixture.scanner
        let path = file.path
        let target = fixture.target
        let outcome = await within(20, "cancel verify") {
            let verification = Task { await scanner.verifyFinding(path: path) }
            while scan.launchCount == 0 {
                try? await Task.sleep(for: .milliseconds(2))
            }
            var refused: [ScanEvent] = []
            for await event in scanner.scan(.custom(target)) {
                refused.append(event)
            }
            await scanner.cancelScan()
            return await (refused, verification.value)
        }
        let (refused, result) = try #require(outcome)
        #expect(refused == [.failed(message: "A scan is already running")])
        #expect(result == .failed(message: "The check was cancelled"))
        #expect(scan.signals.count == 1)
        #expect(scan.signals.first?.group == true)
    }
}
