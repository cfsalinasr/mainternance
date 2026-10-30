import Foundation
import MainternanceDomain
import Synchronization

/// Installs ClamAV through Homebrew and keeps the app-owned virus definitions up to date.
///
/// Only the located `brew` and `freshclam` are run, with argument arrays (no shell, never `sudo`). Everything the
/// installer writes is below `paths.root`; Homebrew's own configuration is never touched. Only one install or
/// definitions update runs at a time.
public final class ClamAVInstaller: Sendable {
    static let homebrewMissingMessage = "Homebrew was not found. Install it from https://brew.sh and try again."
    static let busyMessage = "Another install or update is already running"
    static let notInstalledMessage = "ClamAV is not installed"
    static let brewEnvironment = ["HOMEBREW_NO_AUTO_UPDATE": "1", "HOMEBREW_NO_ENV_HINTS": "1"]

    private let locator: ToolLocator
    private let runner: ProcessRunning
    private let paths: ClamAVPaths
    private let state = Mutex(State())

    /// `busy` is the single-flight flag; `current` is the running brew or freshclam, kept for `terminateNow()`.
    private struct State {
        var busy = false
        var current: RunningProcess?
    }

    public init(locator: ToolLocator, runner: ProcessRunning, paths: ClamAVPaths) {
        self.locator = locator
        self.runner = runner
        self.paths = paths
    }

    /// Both `clamscan` and `freshclam` are present.
    public func isInstalled() -> Bool {
        locator.path(for: "clamscan") != nil && locator.path(for: "freshclam") != nil
    }

    /// Runs `brew install clamav`. Cancelling the consumer of the stream terminates brew's process group
    /// (SIGTERM, then SIGKILL after 2 s while the group leader is still alive; helpers that outlive an already
    /// exited leader are not chased).
    public func install() -> AsyncStream<InstallEvent> {
        stream { [self] continuation in await runInstall(continuation) }
    }

    /// Downloads the virus definitions into the app-owned database with `freshclam`. `.progress` restarts from 0
    /// for each database file (daily, main, bytecode), so a value of 1 is NOT completion: only `.finished` is.
    public func updateDefinitions() -> AsyncStream<InstallEvent> {
        stream { [self] continuation in await runUpdate(continuation) }
    }

    /// Synchronous, idempotent SIGKILL of the running install or update (its whole process group); a no-op when
    /// nothing runs. Safe from any thread. The app target MUST call it on quit (`applicationWillTerminate`),
    /// otherwise brew or freshclam outlive the app; Tasks 5/7 wire that. A call that lands in the instant between
    /// claiming the single-flight slot and starting the child does not stop that child.
    public func terminateNow() {
        let process = state.withLock { $0.current }
        process?.terminateNow()
    }

    // MARK: - Single-flight stream plumbing

    private func stream(
        _ body: @escaping @Sendable (AsyncStream<InstallEvent>.Continuation) async -> Void
    ) -> AsyncStream<InstallEvent> {
        let claimed = state.withLock { current -> Bool in
            guard !current.busy else { return false }
            current.busy = true
            return true
        }
        return AsyncStream { continuation in
            guard claimed else {
                continuation.yield(.failed(message: Self.busyMessage))
                continuation.finish()
                return
            }
            let task = Task { [self] in
                await body(continuation)
                state.withLock {
                    $0.current = nil
                    $0.busy = false
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Install

    private func runInstall(_ continuation: AsyncStream<InstallEvent>.Continuation) async {
        guard let brew = locator.path(for: "brew") else {
            continuation.yield(.failed(message: Self.homebrewMissingMessage))
            return
        }
        let process = runner.run(
            brew,
            arguments: ["install", "clamav"],
            environment: Self.brewEnvironment,
            lowPriority: true
        )
        state.withLock { $0.current = process }
        var tail = StderrTail()
        var lastStage: String?
        for await line in process.lines {
            switch line {
            case let .stdout(text):
                tail.add(text, isStderr: false)
                if let stage = Self.brewStage(for: text), stage != lastStage {
                    lastStage = stage
                    continuation.yield(.stage(stage))
                }
            case let .stderr(text):
                tail.add(text, isStderr: true)
                if let stage = Self.brewStage(for: text), stage != lastStage {
                    lastStage = stage
                    continuation.yield(.stage(stage))
                }
            }
        }
        if Task.isCancelled {
            await process.terminate(killGroup: true)
            return
        }
        let status = await process.wait()
        if status == 0, isInstalled() {
            continuation.yield(.finished)
        } else if status == 0 {
            continuation.yield(.failed(
                message: "Homebrew finished, but ClamAV was not found afterwards. Try again."
            ))
        } else {
            continuation.yield(.failed(message: tail.failureMessage(prefix: "Homebrew failed (exit \(status))")))
        }
    }

    /// Maps a recognizable brew output line to a user-facing stage; nil for everything else.
    static func brewStage(for line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("==>") else { return nil }
        let rest = trimmed.dropFirst(3).trimmingCharacters(in: .whitespaces).lowercased()
        if rest.hasPrefix("downloading") || rest.hasPrefix("fetching") {
            return "Downloading ClamAV…"
        }
        if rest.hasPrefix("pouring") {
            return "Installing ClamAV…"
        }
        if rest.hasPrefix("summary") {
            return "Finishing…"
        }
        return nil
    }

    // MARK: - Definitions

    private func runUpdate(_ continuation: AsyncStream<InstallEvent>.Continuation) async {
        guard let freshclam = locator.path(for: "freshclam") else {
            continuation.yield(.failed(message: Self.notInstalledMessage))
            return
        }
        do {
            try prepareDirectoriesAndConfig()
        } catch {
            continuation.yield(.failed(message: "Could not prepare the ClamAV folder: \(Self.sanitized("\(error)"))"))
            return
        }
        continuation.yield(.stage("Downloading definitions…"))
        let process = runner.run(
            freshclam,
            arguments: ["--config-file=\(paths.freshclamConfig.path)", "--stdout", "--no-warnings", "--show-progress"],
            environment: nil,
            lowPriority: true
        )
        state.withLock { $0.current = process }
        var tail = StderrTail()
        var lastProgress: Double?
        for await line in process.lines {
            switch line {
            case let .stdout(text):
                // `--stdout` sends every freshclam message, errors included, to stdout.
                if let value = Self.parseFreshclamProgress(text) {
                    if value != lastProgress {
                        lastProgress = value
                        continuation.yield(.progress(value))
                    }
                } else {
                    tail.add(text, isStderr: false)
                }
            case let .stderr(text):
                tail.add(text, isStderr: true)
            }
        }
        if Task.isCancelled {
            await process.terminate(killGroup: true)
            return
        }
        let status = await process.wait()
        if status == 0, DefinitionsStore(paths: paths).definitionsDate() != nil {
            continuation.yield(.finished)
        } else if status == 0 {
            continuation.yield(.failed(message: "The download finished, but no virus definitions were saved."))
        } else {
            let prefix = "Updating definitions failed (exit \(status))"
            continuation.yield(.failed(message: tail.failureMessage(prefix: prefix)))
        }
    }

    private func prepareDirectoriesAndConfig() throws {
        let database = paths.databaseDirectory
        guard Self.isSafeConfigValue(database.path) else { throw InstallerError.unsafePath }
        let manager = FileManager.default
        for directory in [paths.supportDirectory, paths.root, database] {
            try manager.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        }
        // createDirectory only applies attributes to directories it creates; make the app folder private anyway.
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: paths.supportDirectory.path)
        let config = Self.freshclamConfig(databaseDirectory: database)
        try Data(config.utf8).write(to: paths.freshclamConfig, options: .atomic)
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: paths.freshclamConfig.path)
    }

    /// Minimal freshclam configuration: the app-owned database and the official mirror. ClamAV config values run
    /// to the end of the line, so the path is written unquoted (spaces are fine). Callers must reject paths for
    /// which `isSafeConfigValue` is false; `updateDefinitions` does.
    public static func freshclamConfig(databaseDirectory: URL) -> String {
        "DatabaseDirectory \(databaseDirectory.path)\nDatabaseMirror database.clamav.net\n"
    }

    /// False when the value contains a line break or a NUL, which would inject extra config lines.
    static func isSafeConfigValue(_ value: String) -> Bool {
        !value.unicodeScalars.contains { $0 == "\n" || $0 == "\r" || $0 == "\0" }
    }
}

enum InstallerError: Error {
    case unsafePath
}
