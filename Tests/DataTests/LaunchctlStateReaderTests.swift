import Foundation
@testable import MainternanceData
import MainternanceDomain
import Testing

/// `launchctl print-disabled` through a fake runner: only the exact shape this Mac prints counts.
@Suite("launchctl state reader")
struct LaunchctlStateReaderTests {
    private let sample: [String] = [
        "\tdisabled services = {",
        "\t\t\"com.example.on\" => enabled",
        "\t\t\"com.example.off\" => disabled",
        "\t\t\"S8EX82NJP6.com.macpaw.CleanMyMac-mas.HealthMonitor\" => enabled",
        "\t}"
    ]

    @Test("the printed block maps each label to enabled or disabled")
    func parsesSample() {
        let states = LaunchctlStateReader.parse(sample)
        #expect(states == [
            "com.example.on": true, "com.example.off": false,
            "S8EX82NJP6.com.macpaw.CleanMyMac-mas.HealthMonitor": true
        ])
        #expect(LaunchctlStateReader.parse(["", "\tdisabled services = {", "\t}", ""]) == [:])
    }

    @Test("anything but the expected block is unknown, never 'enabled'", arguments: [
        [String](),
        ["Usage: launchctl print-disabled <domain-target>"],
        ["\tdisabled services = {", "\t\t\"com.a\" => enabled"], // never closed
        ["\tdisabled services = {", "\t\t\"com.a\" => maybe", "\t}"],
        ["\tdisabled services = {", "\t\tcom.a => enabled", "\t}"],
        ["\tdisabled services = {", "\t\t\"com.a\" => true", "\t}"],
        ["\tdisabled services = {", "\t}", "something else"],
        ["preamble", "\tdisabled services = {", "\t}"],
        ["\tdisabled services = {", "\t\t\"\" => enabled", "\t}"]
    ])
    func unexpectedTextIsUnknown(_ lines: [String]) {
        #expect(LaunchctlStateReader.parse(lines) == nil)
    }

    @Test("the user and system domains are asked with an argument array, through /bin/launchctl")
    func exactCommands() async {
        let launchctl = FakeLaunchctl()
        launchctl.configure {
            $0.user = sample.map(ProcessLine.stdout)
            $0.system = FakeLaunchctl.disabledOutput([("com.example.daemon", false)])
        }
        let reader = LaunchctlStateReader(runner: launchctl.runner, uid: 501)
        #expect(await reader.states(.user)?["com.example.off"] == false)
        #expect(await reader.states(.system) == ["com.example.daemon": false])
        #expect(launchctl.calls == [
            ["/bin/launchctl", "print-disabled", "gui/501"], ["/bin/launchctl", "print-disabled", "system"]
        ])
    }

    @Test("a failing or missing launchctl gives unknown", arguments: [Int32(1), 127, 143])
    func failureIsUnknown(_ status: Int32) async {
        let launchctl = FakeLaunchctl()
        launchctl.configure {
            $0.user = sample.map(ProcessLine.stdout)
            $0.userStatus = status
        }
        let reader = LaunchctlStateReader(runner: launchctl.runner, uid: 501)
        #expect(await reader.states(.user) == nil)
    }

    @Test("text on stderr makes the answer unknown even with exit 0")
    func stderrIsUnknown() async {
        let launchctl = FakeLaunchctl()
        launchctl.configure { $0.user = sample.map(ProcessLine.stdout) + [.stderr("warning: odd")] }
        let reader = LaunchctlStateReader(runner: launchctl.runner, uid: 501)
        #expect(await reader.states(.user) == nil)
    }

    @Test("a launchctl that never ends is stopped after the timeout and gives unknown")
    func hangingIsUnknown() async {
        let (stream, continuation) = AsyncStream.makeStream(of: ProcessLine.self)
        let made = RunningProcess.controllable(lines: stream, onTerminate: { continuation.finish() })
        let runner = FakeRunner { _ in made.process }
        let reader = LaunchctlStateReader(runner: runner, uid: 501, timeout: .milliseconds(50))
        let result = await within(5, "the timeout must end a hanging launchctl") { await reader.states(.user) }
        #expect(result == .some(nil))
        #expect(!made.process.isRunning)
    }
}
