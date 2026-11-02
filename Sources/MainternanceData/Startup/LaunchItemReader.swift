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
        return StartupItem(
            kind: kind, plistPath: path, label: label, program: program, runsAtLoad: job["RunAtLoad"] as? Bool
        )
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

    /// The file's bytes, read through one descriptor opened non-blocking (a FIFO cannot hang the reader) and checked
    /// with `fstat` on that same descriptor (no swap between the check and the read).
    static func readBounded(_ path: String) -> Result<Data, ReadProblem> {
        let descriptor = open(path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { return .failure(.cannotOpen(String(cString: strerror(errno)))) }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { return .failure(.notRegularFile) }
        guard info.st_size <= maxBytes else { return .failure(.tooLarge) }
        var data = Data()
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        while data.count <= maxBytes {
            let count = chunk.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, $0.count) }
            if count > 0 {
                data.append(contentsOf: chunk[0 ..< count])
            } else if count == 0 {
                return .success(data)
            } else if errno != EINTR {
                return .failure(.cannotOpen(String(cString: strerror(errno))))
            }
        }
        return .failure(.tooLarge) // it grew past the limit after it was checked
    }
}
