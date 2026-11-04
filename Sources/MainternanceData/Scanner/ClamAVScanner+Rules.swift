import Foundation
import MainternanceDomain

extension ClamAVScanner {
    /// Without it clamscan silently skips a file over its size or scan limits (`--max-filesize` and friends) and
    /// still prints `OK`. With it each such file is reported as `Heuristics.Limits.Exceeded.* FOUND`, which the
    /// parser counts as "too large to scan", never as scanned and never as a finding.
    static let alertExceedsMax = "--alert-exceeds-max=yes"

    /// The argv of a scan: options first, then `--`, then the roots (so a folder named like an option is data).
    /// No `--no-summary`: the closing `Infected files:` total is how a detection whose line was lost is noticed.
    static func scanArguments(database: String, excluded: [String], roots: [String]) -> [String] {
        ["--database=\(database)", "-v", alertExceedsMax, "--recursive"]
            + ScanExclusions.arguments(for: excluded) + ["--"] + roots
    }

    /// Pure exit-code mapping, see the type documentation.
    static func outcome(
        status: Int32,
        cancelled: Bool,
        tally: ScanTally,
        tail: StderrTail,
        summary: () -> ScanSummary
    ) -> ScanEvent {
        if cancelled || status == 0 || status == 1 {
            return .finished(summary())
        }
        if status == 2, tally.scanned > 0, !tally.fatalSeen {
            return .finished(summary())
        }
        var prefix = "The scan failed (exit \(status))"
        if tally.findings > 0 {
            prefix += " after reporting \(tally.findings) finding\(tally.findings == 1 ? "" : "s")"
        }
        if tally.unattributedDetections > 0 {
            // The `.found` events already delivered and this count are real; the message must carry the count.
            prefix += ScanFailureNote.unattributedClause(tally.unattributedDetections)
        }
        return .failed(message: tail.failureMessage(prefix: prefix))
    }

    /// Why a scan cannot start, nil when it can. `updateNeeded(nil)` means there is no definitions database at all.
    static func refusal(_ status: EngineStatus) -> String? {
        switch status {
        case .ready, .updateNeeded(definitionsAge: .some): nil
        case .updateNeeded(definitionsAge: .none): "there are no virus definitions yet"
        case .homebrewMissing: "ClamAV is not installed and Homebrew was not found"
        case .notInstalled: "ClamAV is not installed"
        case .installing: "ClamAV is still being installed"
        case .downloadingDefinitions: "virus definitions are still downloading"
        case let .failed(message): message
        }
    }
}
