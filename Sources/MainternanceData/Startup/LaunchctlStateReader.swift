import Foundation

/// Reads which jobs launchd has switched off, from `launchctl print-disabled <domain>`.
///
/// Only the exact shape macOS prints counts: a `disabled services = {` line, then one `"<label>" => enabled` or
/// `"<label>" => disabled` line per entry, then `}`. Reading stops at that first `}`: later blocks (such as
/// `login item associations = { ... }`) are ignored. Anything else (no block, an unexpected line inside it, a block
/// that never closes, text on stderr, a non-zero exit, a missing launchctl, a timeout) makes the whole answer unknown
/// (nil), never "enabled".
struct LaunchctlStateReader: Sendable {
    enum Domain: Sendable {
        /// `gui/<uid>`: the owner's login session, where agents (theirs and those for all users) run.
        case user
        /// `system`: where daemons run.
        case system
    }

    private let command: LaunchctlCommand
    private let uid: uid_t

    init(runner: any ProcessRunning, uid: uid_t, timeout: Duration = .seconds(10)) {
        command = LaunchctlCommand(runner: runner, timeout: timeout)
        self.uid = uid
    }

    /// Label -> enabled, as launchd overrides it. A label with no entry follows its plist's `Disabled` key; nil means
    /// launchd's answer is unknown.
    func states(_ domain: Domain) async -> [String: Bool]? {
        let target = switch domain {
        case .user: "gui/\(uid)"
        case .system: "system"
        }
        let output = await command.run(["print-disabled", target])
        guard output.status == 0, output.stderr.allSatisfy({ $0.trimmingCharacters(in: .whitespaces).isEmpty })
        else { return nil }
        return Self.parse(output.stdout)
    }

    static func parse(_ lines: [String]) -> [String: Bool]? {
        var states: [String: Bool] = [:]
        var opened = false
        for raw in lines {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty {
                continue
            }
            if !opened {
                guard line == "disabled services = {" else { return nil }
                opened = true
            } else if line == "}" {
                return states // the block is complete; whatever follows is another block
            } else {
                guard let (label, enabled) = entry(line) else { return nil }
                states[label] = enabled
            }
        }
        return nil // no block, or one that never closed
    }

    /// `"<label>" => enabled|disabled`; the label is everything between the first and the last quote.
    private static func entry(_ line: String) -> (String, Bool)? {
        let enabled: Bool
        let quotedLabel: Substring
        if line.hasSuffix("\" => enabled") {
            enabled = true
            quotedLabel = line.dropLast(" => enabled".count)
        } else if line.hasSuffix("\" => disabled") {
            enabled = false
            quotedLabel = line.dropLast(" => disabled".count)
        } else {
            return nil
        }
        guard quotedLabel.count > 2, quotedLabel.hasPrefix("\""), quotedLabel.hasSuffix("\"") else { return nil }
        return (String(quotedLabel.dropFirst().dropLast()), enabled)
    }
}
