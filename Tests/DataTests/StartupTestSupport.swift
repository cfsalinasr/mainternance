import Foundation
@testable import MainternanceData
import MainternanceDomain
import Synchronization

/// A scripted `launchctl`: what `print-disabled` prints for each domain, and how `enable`/`disable` end.
/// Every call is recorded by the underlying `FakeRunner`; nothing reaches the real launchd.
final class FakeLaunchctl: Sendable {
    struct Script {
        var user: [ProcessLine] = []
        var userStatus: Int32 = 0
        var system: [ProcessLine] = []
        var systemStatus: Int32 = 0
        var control: [ProcessLine] = []
        var controlStatus: Int32 = 0
    }

    private final class Box: Sendable {
        let script = Mutex(Script())
    }

    private let box: Box
    let runner: FakeRunner

    init() {
        let box = Box()
        runner = FakeRunner { call in
            let current = box.script.withLock { $0 }
            return switch call.arguments.first {
            case "print-disabled" where call.arguments.last == "system":
                RunningProcess.finished(lines: current.system, status: current.systemStatus)
            case "print-disabled":
                RunningProcess.finished(lines: current.user, status: current.userStatus)
            default:
                RunningProcess.finished(lines: current.control, status: current.controlStatus)
            }
        }
        self.box = box
    }

    func configure(_ body: (inout Script) -> Void) {
        box.script.withLock { body(&$0) }
    }

    var calls: [[String]] {
        runner.recorded.map { [$0.executable] + $0.arguments }
    }

    /// `print-disabled` output in the shape this Mac prints it.
    static func disabledOutput(_ entries: [(String, Bool)]) -> [ProcessLine] {
        [.stdout("\tdisabled services = {")]
            + entries.map { .stdout("\t\t\"\($0.0)\" => \($0.1 ? "enabled" : "disabled")") }
            + [.stdout("\t}")]
    }
}

/// Temp launchd folders (user agents, agents for all users, daemons) plus a review folder and a fake Trash.
/// Never the real `~/Library`, `/Library`, Application Support or Trash.
struct StartupFixture {
    let temp: TempDirectory
    let launchctl = FakeLaunchctl()
    let trash: FakeTrash

    init() throws {
        temp = try TempDirectory()
        trash = FakeTrash(folder: temp.url.appendingPathComponent("trash", isDirectory: true))
        for source in sources {
            try FileManager.default.createDirectory(at: source.folder, withIntermediateDirectories: true)
        }
    }

    var userFolder: URL {
        temp.url.appendingPathComponent("home/Library/LaunchAgents", isDirectory: true)
    }

    var agentFolder: URL {
        temp.url.appendingPathComponent("Library/LaunchAgents", isDirectory: true)
    }

    var daemonFolder: URL {
        temp.url.appendingPathComponent("Library/LaunchDaemons", isDirectory: true)
    }

    var reviewFolder: URL {
        temp.url.appendingPathComponent("support", isDirectory: true)
    }

    var reviewFile: URL {
        reviewFolder.appendingPathComponent("startup-review.json")
    }

    var sources: [LaunchItemSource] {
        [
            LaunchItemSource(folder: userFolder, kind: .userAgent),
            LaunchItemSource(folder: agentFolder, kind: .systemAgent),
            LaunchItemSource(folder: daemonFolder, kind: .systemDaemon)
        ]
    }

    var reader: LaunchItemReader {
        LaunchItemReader(sources: sources)
    }

    typealias PathGuard = @Sendable (String) -> Bool

    func services(
        isProtected: @escaping PathGuard = { ProtectedPaths.isProtected($0) },
        clock: @escaping @Sendable () -> Date = { Date(timeIntervalSince1970: 1_800_000_000) }
    ) -> StartupServices {
        let fake = trash
        return StartupServices(
            runner: launchctl.runner, directory: reviewFolder, uid: 501, sources: sources,
            now: { Date(timeIntervalSince1970: 1_800_000_000) }, clock: clock, trash: { try fake.trash($0) },
            isProtected: isProtected
        )
    }

    /// Writes a launchd property list (XML unless `binary`) and returns its path.
    @discardableResult
    func plist(
        _ name: String, in folder: URL, _ contents: [String: Any], binary: Bool = false
    ) throws -> String {
        let data = try PropertyListSerialization.data(
            fromPropertyList: contents, format: binary ? .binary : .xml, options: 0
        )
        let url = folder.appendingPathComponent(name)
        try data.write(to: url)
        return url.path
    }

    /// A minimal job: a label and a program.
    @discardableResult
    func job(_ label: String, in folder: URL, file: String? = nil) throws -> String {
        try plist(file ?? "\(label).plist", in: folder, ["Label": label, "ProgramArguments": ["/bin/true"]])
    }

    @discardableResult
    func raw(_ name: String, in folder: URL, _ data: Data) throws -> String {
        let url = folder.appendingPathComponent(name)
        try data.write(to: url)
        return url.path
    }

    /// A snapshot holding one of the owner's agents per label, as the screen hands it to `markReviewed`.
    static func listing(_ labels: String...) -> StartupSnapshot {
        StartupSnapshot(items: labels.map {
            StartupItem(kind: .userAgent, plistPath: "/nowhere/\($0).plist", label: $0)
        })
    }

    func names(in folder: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).sorted()
    }
}
