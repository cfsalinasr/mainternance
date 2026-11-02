import Foundation
@testable import MainternanceData
import MainternanceDomain
import Testing

/// Switching user agents through a fake `launchctl`: exact arguments, refusals, readable failures.
@Suite("launchctl controller")
struct LaunchctlControllerTests {
    private func agent(_ label: String?, kind: StartupKind = .userAgent, problem: String? = nil) -> StartupItem {
        StartupItem(kind: kind, plistPath: "/tmp/fake/a.plist", label: label, readProblem: problem)
    }

    @Test("disable and enable run exactly launchctl <verb> gui/<uid>/<label>")
    func exactArguments() async throws {
        let launchctl = FakeLaunchctl()
        let controller = LaunchctlController(runner: launchctl.runner, uid: 501)
        try await controller.setEnabled(agent("com.example.updater"), false)
        try await controller.setEnabled(agent("com.example.updater"), true)
        #expect(launchctl.calls == [
            ["/bin/launchctl", "disable", "gui/501/com.example.updater"],
            ["/bin/launchctl", "enable", "gui/501/com.example.updater"]
        ])
        #expect(launchctl.runner.recorded.allSatisfy { $0.environment == nil && !$0.lowPriority })
    }

    @Test("agents for all users, daemons and unreadable files are refused without running anything")
    func notAllowed() async {
        let launchctl = FakeLaunchctl()
        let controller = LaunchctlController(runner: launchctl.runner, uid: 501)
        for item in [
            agent("com.a", kind: .systemAgent), agent("com.a", kind: .systemDaemon), agent("com.a", problem: "bad")
        ] {
            await #expect(throws: StartupError.notAllowed) { try await controller.setEnabled(item, false) }
        }
        #expect(launchctl.calls.isEmpty)
    }

    @Test("a label that is missing or unsafe never reaches launchctl", arguments: [
        nil, "", "--version", "../x", "a/b", "line\nbreak", String(repeating: "a", count: 300)
    ])
    func invalidLabel(_ label: String?) async {
        let launchctl = FakeLaunchctl()
        let controller = LaunchctlController(runner: launchctl.runner, uid: 501)
        await #expect(throws: StartupError.invalidLabel) { try await controller.setEnabled(agent(label), true) }
        #expect(launchctl.calls.isEmpty)
    }

    @Test("a non-zero exit is a failure carrying the last line launchctl wrote to stderr")
    func failureCarriesReason() async {
        let launchctl = FakeLaunchctl()
        launchctl.configure {
            $0.control = [.stderr("Some first line"), .stdout("noise"), .stderr("Operation not permitted"), .stderr("")]
            $0.controlStatus = 1
        }
        let controller = LaunchctlController(runner: launchctl.runner, uid: 501)
        await #expect(throws: StartupError.failed("Operation not permitted")) {
            try await controller.setEnabled(agent("com.a"), false)
        }
    }

    @Test("a non-zero exit without any message still says what happened")
    func failureWithoutText() async {
        let launchctl = FakeLaunchctl()
        launchctl.configure { $0.controlStatus = 3 }
        let controller = LaunchctlController(runner: launchctl.runner, uid: 501)
        await #expect(throws: StartupError.failed("launchctl ended with status 3.")) {
            try await controller.setEnabled(agent("com.a"), true)
        }
    }

    @Test("a very long error line is shortened before it is shown")
    func longReasonIsShortened() async {
        let launchctl = FakeLaunchctl()
        launchctl.configure {
            $0.control = [.stderr(String(repeating: "x", count: 5000))]
            $0.controlStatus = 1
        }
        let controller = LaunchctlController(runner: launchctl.runner, uid: 501)
        do {
            try await controller.setEnabled(agent("com.a"), true)
            Issue.record("expected a failure")
        } catch let StartupError.failed(reason) {
            #expect(reason.count <= LaunchctlCommand.maxReasonLength + 1)
            #expect(reason.hasSuffix("…"))
        } catch {
            Issue.record("unexpected error \(error)")
        }
    }
}
