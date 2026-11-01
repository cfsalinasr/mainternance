import Foundation
@testable import MainternanceData
import MainternanceDomain
import Synchronization
import Testing

@Suite("Scanner services")
struct ScannerServicesTests {
    @Test("terminateNow stops a running install and keeps a later scan from starting")
    func quitHookReachesBoth() async throws {
        let temp = try TempDirectory()
        let paths = ClamAVPaths(supportDirectory: temp.url.appendingPathComponent("support"))
        try FileManager.default.createDirectory(at: paths.databaseDirectory, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: paths.databaseDirectory.appendingPathComponent("daily.cvd"))
        let target = temp.url.appendingPathComponent("target", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let signals = SignalLog()
        let runner = FakeRunner { _ in
            let (stream, source) = AsyncStream<ProcessLine>.makeStream()
            let (process, _) = RunningProcess.controllable(lines: stream, onSignal: { signal, _ in
                signals.add(signal)
                source.finish()
            })
            return process
        }
        let services = ScannerServices(
            paths: paths, locator: FakeTools(["brew", "clamscan", "freshclam"]).locator, runner: runner,
            home: temp.url
        )
        let install = services.installer.install()
        let deadline = Date().addingTimeInterval(10)
        while runner.recorded.isEmpty, Date() < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(runner.recorded.count == 1)
        services.terminateNow()
        let installEvents = await collectEvents(install)
        #expect(signals.all == [SIGKILL])
        guard case .failed? = installEvents.last else {
            Issue.record("expected the install to fail after the kill, got \(installEvents)")
            return
        }
        var scanEvents: [ScanEvent] = []
        for await event in services.scanner.scan(.custom(target)) {
            scanEvents.append(event)
        }
        #expect(runner.recorded.count == 1, "no clamscan may start after the quit")
        guard case let .failed(message)? = scanEvents.last else {
            Issue.record("expected the scan to be refused, got \(scanEvents)")
            return
        }
        #expect(message.contains("quitting"))
    }

    @Test("the quarantine folder is the app's own folder and both own folders are protected from custom scans")
    func folders() throws {
        let temp = try TempDirectory()
        let paths = ClamAVPaths(supportDirectory: temp.url.appendingPathComponent("support"))
        let services = ScannerServices(paths: paths, locator: FakeTools([]).locator, home: temp.url)
        #expect(services.paths.quarantineDirectory.lastPathComponent == "Quarantine")
        #expect(services.ownFolders == [paths.quarantineDirectory, paths.root])
        #expect(ClamAVPaths().quarantineDirectory.path
            .hasSuffix("/Library/Application Support/Mainternance/Quarantine"))
    }
}
