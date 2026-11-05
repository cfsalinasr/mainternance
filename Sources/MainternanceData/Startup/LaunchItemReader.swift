import CryptoKit
import Darwin
import Foundation
import MainternanceDomain

/// One folder launchd reads jobs from, and the kind of job it holds.
struct LaunchItemSource: Sendable, Equatable {
    let folder: URL
    let kind: StartupKind
}

/// Reads the launchd property lists in the given folders. Read-only: it opens each `.plist` file to parse it and
/// touches nothing else (the program a job names is shown, never opened or run).
///
/// Every `.plist` file becomes a row; one that cannot be read becomes a row with `readProblem` set, never dropped.
/// A file is opened non-blocking and must be a regular file of at most `maxBytes` (a symlinked plist is read
/// through its link, once, under the link's own path; a FIFO, a device or a folder is a row that could not be read).
struct LaunchItemReader: Sendable {
    /// Larger files are not parsed.
    static let maxBytes = 1 << 20

    let sources: [LaunchItemSource]

    /// The owner's agents, agents for all users and system daemons. The last two are fixed macOS locations.
    static func standardSources(home: URL) -> [LaunchItemSource] {
        [
            LaunchItemSource(folder: home.appendingPathComponent("Library/LaunchAgents", isDirectory: true),
                             kind: .userAgent),
            LaunchItemSource(folder: URL(fileURLWithPath: "/Library/LaunchAgents", isDirectory: true),
                             kind: .systemAgent),
            LaunchItemSource(folder: URL(fileURLWithPath: "/Library/LaunchDaemons", isDirectory: true),
                             kind: .systemDaemon)
        ]
    }

    /// The rows sorted by kind, then name (then path); and the folders that exist but could not be opened.
    func read() -> (items: [StartupItem], unreadableFolders: [String]) {
        var items: [StartupItem] = []
        var unreadable: [String] = []
        let manager = FileManager.default
        for source in sources {
            let folder = source.folder.path
            guard manager.fileExists(atPath: folder) else { continue }
            guard let names = try? manager.contentsOfDirectory(atPath: folder) else {
                unreadable.append(folder)
                continue
            }
            for name in names where name.hasSuffix(".plist") {
                let path = source.folder.appendingPathComponent(name).path
                items.append(Self.item(at: path, kind: source.kind))
            }
        }
        let order = StartupKind.allCases
        items.sort { lhs, rhs in
            let left = (order.firstIndex(of: lhs.kind) ?? 0, lhs.name.lowercased(), lhs.plistPath)
            let right = (order.firstIndex(of: rhs.kind) ?? 0, rhs.name.lowercased(), rhs.plistPath)
            return left < right
        }
        return (items, unreadable)
    }

    static func item(at path: String, kind: StartupKind) -> StartupItem {
        let data: Data
        switch readBounded(path) {
        case let .success(bytes):
            data = bytes
        case let .failure(problem):
            return StartupItem(kind: kind, plistPath: path, readProblem: problem.text)
        }
        guard let parsed = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) else {
            return StartupItem(kind: kind, plistPath: path, readProblem: ReadProblem.notPropertyList.text)
        }
        guard let job = parsed as? [String: Any] else {
            return StartupItem(kind: kind, plistPath: path, readProblem: ReadProblem.notDictionary.text)
        }
        let label = (job["Label"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let program = (job["Program"] as? String) ?? ((job["ProgramArguments"] as? [Any])?.first as? String)
        var item = StartupItem(
            kind: kind, plistPath: path, label: label, program: program, runsAtLoad: job["RunAtLoad"] as? Bool,
            disabledInFile: (job["Disabled"] as? Bool) == true
        )
        item.programFingerprint = programFingerprint(job)
        item.previousFingerprint = programOnlyFingerprint(job)
        return item
    }

    /// SHA-256 (hex) of what decides what the job runs: `Program`, every `ProgramArguments` entry,
    /// `EnvironmentVariables` (sorted by name, so it is stable), `BundleProgram` and `WorkingDirectory`. Each part is
    /// tagged and NUL-separated so no two different jobs give the same text; nil when the file names none of them.
    /// A value that is not text is hashed by its description, so it still counts.
    static func programFingerprint(_ job: [String: Any]) -> String? {
        let fields = ["Program", "ProgramArguments", "EnvironmentVariables", "BundleProgram", "WorkingDirectory"]
        guard fields.contains(where: { job[$0] != nil }) else { return nil }
        var parts = programParts(job)
        let environment = job["EnvironmentVariables"] as? [String: Any]
        parts += [
            "environment",
            environment.map { String($0.count) } ?? job["EnvironmentVariables"].map(describe) ?? "-"
        ]
        parts += (environment ?? [:]).sorted { $0.key < $1.key }.map { "\($0.key)=" + describe($0.value) }
        parts += ["bundle", job["BundleProgram"].map(describe) ?? "-"]
        parts += ["directory", job["WorkingDirectory"].map(describe) ?? "-"]
        return hash(["v2"] + parts)
    }

    /// The fingerprint of reviews saved before the environment, bundle program and working directory counted
    /// (`Program` and `ProgramArguments` only). Only used to upgrade such a review once.
    static func programOnlyFingerprint(_ job: [String: Any]) -> String? {
        guard job["Program"] != nil || job["ProgramArguments"] != nil else { return nil }
        return hash(programParts(job))
    }

    private static func programParts(_ job: [String: Any]) -> [String] {
        let program = job["Program"]
        let arguments = job["ProgramArguments"] as? [Any]
        let head = ["program", program.map(describe) ?? "", "arguments", arguments.map { String($0.count) } ?? "-"]
        return head + (arguments ?? []).map(describe)
    }

    private static func hash(_ parts: [String]) -> String {
        let digest = SHA256.hash(data: Data(parts.joined(separator: "\u{0}").utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func describe(_ value: Any) -> String {
        (value as? String).map { "s:" + $0 } ?? "o:\(value)"
    }

    enum ReadProblem: Error, Equatable {
        case cannotOpen(String)
        case notRegularFile
        case tooLarge
        case notPropertyList
        case notDictionary

        var text: String {
            switch self {
            case let .cannotOpen(reason): "Could not be read: \(reason)."
            case .notRegularFile: "Could not be read: it is not a regular file."
            case .tooLarge: "Could not be read: it is larger than 1 MB."
            case .notPropertyList: "Could not be read: it is not a valid property list."
            case .notDictionary: "Could not be read: it does not contain a dictionary."
            }
        }
    }

    /// The file's bytes, through `BoundedFileRead` (non-blocking, regular files only, at most `maxBytes`).
    static func readBounded(_ path: String) -> Result<Data, ReadProblem> {
        BoundedFileRead.data(at: path, maxBytes: maxBytes).mapError { failure in
            switch failure {
            case .missing: .cannotOpen(String(cString: strerror(ENOENT)))
            case let .cannotOpen(reason): .cannotOpen(reason)
            case .notRegularFile: .notRegularFile
            case .tooLarge: .tooLarge
            }
        }
    }
}
