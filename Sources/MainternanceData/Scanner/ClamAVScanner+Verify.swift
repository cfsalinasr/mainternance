import Foundation
import MainternanceDomain

extension ClamAVScanner {
    /// Re-scans exactly one file with `[clamscan, --database=<dir>, -v, --no-summary, --, <path>]` (low priority).
    ///
    /// Shares the single-flight slot with scans (refused while one runs), is cancelled by `cancelScan()` and by
    /// cancelling the calling task, and obeys `terminateNow()`. `.confirmed` only for a FOUND line whose path is
    /// EXACTLY the requested path (a forged line cannot equal it: output lines never contain a newline, and a path
    /// with a newline can therefore never be confirmed), `.clean` for its OK line with exit 0, otherwise `.failed`.
    /// Only an absolute path of a regular file is accepted: clamscan does not follow symlinks and a directory would
    /// start a recursive scan.
    public func verifyFinding(path: String) async -> VerifyResult {
        guard claimSlot() else { return .failed(message: Self.busyMessage) }
        let result = await runVerification(path)
        releaseSlot()
        return result
    }

    private func runVerification(_ path: String) async -> VerifyResult {
        guard ScanPathRules.isPlainAbsolute(path) else {
            return .failed(message: "Only the full path of a file can be checked")
        }
        guard ScanPathRules.isRegularFile(path) else {
            return .failed(message: "The item is not a regular file any more, so it was not checked")
        }
        if let reason = Self.refusal(statusNow(definitionsDate: definitionsDateNow())) {
            return .failed(message: "Scanning engine is not ready: \(reason)")
        }
        guard let clamscan = locator.path(for: "clamscan") else {
            return .failed(message: "Scanning engine is not ready: ClamAV is not installed")
        }
        let arguments = ["--database=\(paths.databaseDirectory.path)", "-v", "--no-summary", "--", path]
        guard let process = launch(clamscan, arguments) else {
            return .failed(message: "The check was stopped")
        }
        var collector = VerifyCollector(path: path)
        for await output in process.lines {
            switch output {
            case let .stdout(text): collector.add(text, isStderr: false)
            case let .stderr(text): collector.add(text, isStderr: true)
            }
        }
        if Task.isCancelled {
            await process.terminate(killGroup: true)
            return .failed(message: "The check was cancelled")
        }
        let status = await process.wait()
        if state.withLock({ $0.cancelRequested }) {
            return .failed(message: "The check was cancelled")
        }
        return collector.result(status: status)
    }
}

/// Picks the one verdict that names the requested path out of a verification's output.
struct VerifyCollector {
    private let path: String
    private var verdict: ClamLine?
    private var tail = StderrTail()

    init(path: String) {
        self.path = path
    }

    mutating func add(_ text: String, isStderr: Bool) {
        let parsed = ClamScanOutputParser.parse(text)
        switch parsed {
        case let .found(found, _) where found == path:
            if case .found? = verdict {
                return
            }
            verdict = parsed
        case let .scanned(scanned) where scanned == path:
            if verdict == nil {
                verdict = parsed
            }
        default:
            if isStderr, parsed == .ignored {
                tail.add(text, isStderr: true)
            }
        }
    }

    func result(status: Int32) -> VerifyResult {
        switch verdict {
        case let .found(_, signature)?:
            .confirmed(signature: signature)
        case .scanned? where status == 0:
            .clean
        default:
            .failed(message: tail.failureMessage(prefix: "The file could not be checked (exit \(status))"))
        }
    }
}
