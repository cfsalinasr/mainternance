import Foundation
@testable import MainternanceData
import MainternanceDomain
import Testing

@Suite("ClamAV scanner refusals")
struct ClamAVScannerRefusalTests {
    // MARK: refusals

    @Test("refuses without starting a process", arguments: [
        (Set<String>(), "Homebrew"),
        (Set(["brew"]), "not installed"),
        (Set(["clamscan"]), "not installed")
    ])
    func notInstalled(tools: Set<String>, expected: String) async throws {
        let fixture = try ScannerFixture(tools: tools, runner: FakeRunner.replaying([], status: 0))
        let events = await fixture.run()
        let message = try #require(events.failure)
        #expect(message.hasPrefix("Scanning engine is not ready: "))
        #expect(message.contains(expected))
        #expect(fixture.runner.recorded.isEmpty)
        #expect(events.first != .started(scope: .custom(fixture.target)))
    }

    @Test("refuses when there are no definitions")
    func noDefinitions() async throws {
        let fixture = try ScannerFixture(definitionsAge: nil, runner: FakeRunner.replaying([], status: 0))
        let message = try #require(await fixture.run().failure)
        #expect(message.hasPrefix("Scanning engine is not ready: "))
        #expect(message.contains("definitions"))
        #expect(fixture.runner.recorded.isEmpty)
    }

    @Test("old definitions still allow a scan (the UI says how old they are)")
    func staleDefinitionsAllowed() async throws {
        let fixture = try ScannerFixture(
            definitionsAge: 30 * 24 * 3600, runner: FakeRunner.replaying(okLines(1), status: 0)
        )
        #expect(await fixture.run().summary != nil)
        #expect(fixture.runner.recorded.count == 1)
    }

    @Test("status reflects installation and definitions")
    func statusMapping() async throws {
        let ready = try ScannerFixture.replaying([], status: 0)
        #expect(await ready.scanner.status() == .ready(definitionsAge: 3600))
        let none = try ScannerFixture(definitionsAge: nil, runner: FakeRunner.replaying([], status: 0))
        #expect(await none.scanner.status() == .updateNeeded(definitionsAge: nil))
        let absent = try ScannerFixture(tools: ["brew"], runner: FakeRunner.replaying([], status: 0))
        #expect(await absent.scanner.status() == .notInstalled)
    }
}
