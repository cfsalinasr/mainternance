import Foundation
import MainternanceDomain

/// Switches the owner's own agents with `launchctl disable|enable gui/<uid>/<label>`: reversible, no administrator,
/// nothing deleted or moved. macOS applies it at the next login.
///
/// Agents for all users and daemons are refused (`notAllowed`), as is an item whose file could not be read. The
/// label is checked with `StartupItem.isValidLabel` before it is ever passed on (`invalidLabel`), and it travels as
/// part of one argument, never through a shell.
struct LaunchctlController: StartupControlling {
    private let command: LaunchctlCommand
    private let uid: uid_t

    init(runner: any ProcessRunning, uid: uid_t, timeout: Duration = .seconds(10)) {
        command = LaunchctlCommand(runner: runner, timeout: timeout)
        self.uid = uid
    }

    func setEnabled(_ item: StartupItem, _ enabled: Bool) async throws {
        guard item.kind == .userAgent, item.readProblem == nil else { throw StartupError.notAllowed }
        guard let label = item.label, StartupItem.isValidLabel(label) else { throw StartupError.invalidLabel }
        let output = await command.run([enabled ? "enable" : "disable", "gui/\(uid)/\(label)"])
        guard output.status == 0 else { throw StartupError.failed(LaunchctlCommand.reason(output)) }
    }
}
