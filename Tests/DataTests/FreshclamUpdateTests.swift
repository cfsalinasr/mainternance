import Foundation
@testable import MainternanceData
import MainternanceDomain
import Testing

@Suite("ClamAV definitions update")
struct FreshclamUpdateTests {
    private struct Rig {
        let temp: TempDirectory
        let support: URL
        let paths: ClamAVPaths
        let tools: FakeTools
    }

    private func rig(tools: Set<String> = ["freshclam"]) throws -> Rig {
        let temp = try TempDirectory()
        let support = temp.url.appendingPathComponent("Support", isDirectory: true)
        return Rig(temp: temp, support: support, paths: ClamAVPaths(supportDirectory: support), tools: FakeTools(tools))
    }

    private func sut(_ rig: Rig, _ runner: ProcessRunning) -> ClamAVInstaller {
        ClamAVInstaller(locator: rig.tools.locator, runner: runner, paths: rig.paths)
    }

    private func writeDefinitions(_ paths: ClamAVPaths) {
        try? Data("db".utf8).write(to: paths.databaseDirectory.appendingPathComponent("daily.cvd"))
    }

    @Test("without freshclam it fails and starts nothing")
    func missing() async throws {
        let rig = try rig(tools: ["brew"])
        let runner = FakeRunner.replaying([], status: 0)
        let events = await collectEvents(sut(rig, runner).updateDefinitions())
        #expect(events == [.failed(message: "ClamAV is not installed")])
        #expect(runner.recorded.isEmpty)
        #expect(rig.temp.names.isEmpty)
    }

    @Test("exact invocation, config file content and permissions, nothing written outside the root")
    func invocationAndConfig() async throws {
        let rig = try rig()
        let paths = rig.paths
        let runner = FakeRunner.replaying([
            .stdout("daily.cvd database available for update (local version: 1, remote version: 2)"),
            .stdout("Time: 1.0s, ETA: 1.0s [============>   ] 1.00MiB/2.00MiB"),
            .stdout("Time: 4.3s, ETA: 0.0s [=========================>] 62.58MiB/62.58MiB"),
            .stdout("Time: 4.3s, ETA: 0.0s [=========================>] 62.58MiB/62.58MiB")
        ], status: 0, sideEffect: { writeDefinitions(paths) })
        let events = await collectEvents(sut(rig, runner).updateDefinitions())
        #expect(events == [.stage("Downloading definitions…"), .progress(0.5), .progress(1), .finished])

        let call = try #require(runner.recorded.first)
        #expect(runner.recorded.count == 1)
        #expect(call.executable == "/fake/bin/freshclam")
        #expect(call.arguments == ["--config-file=\(paths.freshclamConfig.path)", "--stdout", "--no-warnings"])
        #expect(call.lowPriority)
        #expect(!call.arguments.joined().contains("/opt/homebrew"))

        let config = try String(contentsOf: paths.freshclamConfig, encoding: .utf8)
        #expect(config == ClamAVInstaller.freshclamConfig(databaseDirectory: paths.databaseDirectory))
        #expect(config.contains("DatabaseDirectory \(paths.databaseDirectory.path)"))
        #expect(permissions(paths.supportDirectory) == 0o700)
        #expect(permissions(paths.root) == 0o700)
        #expect(permissions(paths.databaseDirectory) == 0o700)
        #expect(permissions(paths.freshclamConfig) == 0o600)

        #expect(rig.temp.names == ["Support"])
        let supportNames = try (FileManager.default.contentsOfDirectory(atPath: rig.support.path)).sorted()
        #expect(supportNames == ["ClamAV"])
        let rootNames = try (FileManager.default.contentsOfDirectory(atPath: paths.root.path)).sorted()
        #expect(rootNames == ["database", "freshclam.conf"])
    }

    @Test("exit 0 without any database file is a failure")
    func noDatabase() async throws {
        let rig = try rig()
        let runner = FakeRunner.replaying([.stdout("nothing downloaded")], status: 0)
        let events = await collectEvents(sut(rig, runner).updateDefinitions())
        #expect(events.first == .stage("Downloading definitions…"))
        guard case .failed? = events.last else {
            Issue.record("expected failure, got \(events)")
            return
        }
        #expect(!events.contains(.finished))
    }

    @Test("non-zero exit fails with the stderr tail even when an old database exists")
    func nonZero() async throws {
        let rig = try rig()
        let paths = rig.paths
        let runner = FakeRunner.replaying([.stderr("ERROR: Can't connect to database.clamav.net")], status: 52,
                                          sideEffect: { writeDefinitions(paths) })
        let events = await collectEvents(sut(rig, runner).updateDefinitions())
        #expect(events.last == .failed(
            message: "Updating definitions failed (exit 52): ERROR: Can't connect to database.clamav.net"
        ))
    }

    @Test("a support path with spaces is written unquoted")
    func spaces() async throws {
        let temp = try TempDirectory()
        let support = temp.url.appendingPathComponent("Application Support/Mainternance", isDirectory: true)
        let paths = ClamAVPaths(supportDirectory: support)
        let runner = FakeRunner.replaying([], status: 0, sideEffect: { writeDefinitions(paths) })
        let installer = ClamAVInstaller(locator: FakeTools(["freshclam"]).locator, runner: runner, paths: paths)
        let events = await collectEvents(installer.updateDefinitions())
        #expect(events.last == .finished)
        let config = try String(contentsOf: paths.freshclamConfig, encoding: .utf8)
        #expect(config.contains("DatabaseDirectory \(paths.databaseDirectory.path)\n"))
        #expect(paths.databaseDirectory.path.contains("Application Support"))
    }

    @Test("a support path with a newline is rejected and nothing is created or run")
    func newline() async throws {
        let temp = try TempDirectory()
        let support = temp.url.appendingPathComponent("bad\nExample", isDirectory: true)
        let runner = FakeRunner.replaying([], status: 0)
        let installer = ClamAVInstaller(
            locator: FakeTools(["freshclam"]).locator, runner: runner, paths: ClamAVPaths(supportDirectory: support)
        )
        let events = await collectEvents(installer.updateDefinitions())
        guard case .failed? = events.last, events.count == 1 else {
            Issue.record("expected a single failure, got \(events)")
            return
        }
        #expect(runner.recorded.isEmpty)
        #expect(temp.names.isEmpty)
    }
}
