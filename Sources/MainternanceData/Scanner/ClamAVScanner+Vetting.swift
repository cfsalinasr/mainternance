import Foundation
import MainternanceDomain

extension ClamAVScanner {
    /// Drops a verdict whose path cannot be a real result of this scan. A file name may contain newlines and so
    /// forge lines: every path must be plain absolute and below one of the scan roots, and a FOUND path must exist.
    /// This cannot stop a forged line that names a real file inside a root; the consumer re-verifies a finding
    /// (`verifyFinding`) before acting on it.
    func vetted(_ line: ClamLine, context: Context, tally: inout ScanTally) -> ClamLine {
        let path: String
        switch line {
        case .ignored, .infectedTotal: return line
        case let .scanned(value), let .found(value, _), let .unreadable(value, _), let .unreadableFolder(value),
             let .tooLarge(value): path = value
        }
        let isFound = if case .found = line {
            true
        } else {
            false
        }
        // A FOUND line ending in the app's own folders cannot be a result of this scan, but a file name with a
        // newline can make a REAL detection print that way: it is dropped and counted, never silent (a forged line
        // on a clean exit 0 is cleared by `ScanTally.noteExit`).
        let inOwn = ScanPathRules.isPlainAbsolute(path)
            && context.ownDirectories.contains { ScanPathRules.isInside(path, directory: $0) }
        if isFound, inOwn {
            tally.noteSuspicious()
            tally.noteDroppedDetection()
            return .ignored
        }
        let inRoot = ScanPathRules.isPlainAbsolute(path)
            && context.roots.contains { ScanPathRules.isInside(path, directory: $0) }
        // A FOUND inside an excluded CLOUD folder is a real, valid detection (the folder was not scanned, so only an
        // output line can name it): delivered. Other verdicts below any excluded directory are post-filtered.
        let plausible = inRoot
            && (isFound || !context.excluded.contains { ScanPathRules.isInside(path, directory: $0) })
        var accepted = plausible
        if isFound, plausible, !fileExists(path) {
            accepted = false
        }
        // A too-large alert must name a real regular file (lstat), so a forged one cannot offset a detection.
        if case .tooLarge = line, plausible, !isRegularFile(path) {
            accepted = false
        }
        guard accepted else {
            tally.noteSuspicious()
            if isFound {
                // A real detection without a usable path must never vanish silently (exit 0 resets this: see
                // `ScanTally.noteExit`).
                tally.noteDroppedDetection()
            }
            return .ignored
        }
        return line
    }

    func cloudDirectories() -> Set<String> {
        Set(["Library/Mobile Documents", "Library/CloudStorage"].map {
            home.appendingPathComponent($0).standardizedFileURL.path
        })
    }
}
