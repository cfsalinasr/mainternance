import Foundation
import MainternanceDomain

extension ScannerText {
    // MARK: - Scan result

    struct Report: Equatable {
        var title: String
        var symbol: String
        var lines: [String]
    }

    /// What the finished scan says. Plain facts only: what was scanned, how many files, what could not be read,
    /// which definitions, and what was found. "Clean" wording is used only when `isClean` and nothing was skipped.
    static func report(_ summary: ScanSummary, locale: Locale = .current, timeZone: TimeZone = .current) -> Report {
        var lines = [
            scopeLine(summary.scope), "\(files(summary.scanned, locale: locale)) scanned.",
            finishedLine(summary.endedAt, locale: locale, timeZone: timeZone)
        ]
        if summary.unreadable > 0 {
            lines.append("\(files(summary.unreadable, locale: locale)) could not be read and were not scanned.")
        }
        lines.append(definitionsLine(summary.definitionsDate, locale: locale, timeZone: timeZone))
        if summary.cancelled {
            lines.insert("You cancelled this scan, so only part of the files were checked.", at: 1)
        }
        if summary.findings > 0 {
            lines.append("\(files(summary.findings, locale: locale)) flagged as a possible threat.")
        }
        if summary.unattributedDetections > 0 {
            lines.append(unattributed(summary.unattributedDetections))
        }
        if summary.scope == .full {
            lines.append(cloudAdvisory)
        }
        let (title, symbol) = headline(summary)
        return Report(title: title, symbol: symbol, lines: lines)
    }

    private static func headline(_ summary: ScanSummary) -> (String, String) {
        if summary.cancelled {
            return ("Scan cancelled", "stop.circle")
        }
        if !summary.isClean {
            return ("Detections found", "exclamationmark.triangle.fill")
        }
        if summary.isComplete {
            return ("No threats found", "checkmark.circle.fill")
        }
        return ("No threats found in the files that could be read", "exclamationmark.circle")
    }

    static func scopeLine(_ scope: ScanScope) -> String {
        switch scope {
        case .quick: quickScope
        case .full: fullScope
        case let .custom(url): "Scan of \(url.path)."
        }
    }

    static func finishedLine(_ date: Date, locale: Locale, timeZone: TimeZone) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = locale
        calendar.timeZone = timeZone
        let style = Date.FormatStyle(
            date: .abbreviated,
            time: .shortened,
            locale: locale,
            calendar: calendar,
            timeZone: timeZone
        )
        return "Finished \(date.formatted(style))."
    }

    static func definitionsLine(_ date: Date?, locale: Locale, timeZone: TimeZone) -> String {
        guard let date else { return "The date of the virus definitions is unknown." }
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = locale
        calendar.timeZone = timeZone
        let text = date.formatted(
            Date.FormatStyle(date: .abbreviated, time: .omitted, locale: locale, calendar: calendar, timeZone: timeZone)
        )
        return "Virus definitions from \(text)."
    }

    // MARK: - Errors

    enum QuarantineAction {
        case quarantine, restore
    }

    static func message(for error: Error, action: QuarantineAction) -> String {
        guard let error = error as? QuarantineError else {
            return action == .quarantine
                ? "The file could not be moved, so it was left where it is."
                : "The file could not be restored."
        }
        switch error {
        case .protectedPath:
            return "This file is in a protected location (a system, app or home folder), so it was not moved."
        case .notRegularFile:
            return "Only regular files can be quarantined. This is a folder, link or special file, so it was not moved."
        case .missing:
            return action == .quarantine
                ? "The file is no longer there, so nothing was moved."
                : "There is nothing to restore: the quarantined copy is gone."
        case .changedSinceScan:
            return "The file changed since the scan, so it was not moved. Scan again to check it."
        case .restoreTargetMissing:
            return "The folder this file came from no longer exists, so it was not restored."
        case let .ioFailure(detail):
            return action == .quarantine
                ? "The file could not be moved: \(detail). It was left where it is."
                : "The file could not be restored: \(detail)."
        }
    }

    static func verifyClean(_ name: String) -> String {
        "\(name) no longer looks infected, so it was not moved. Scan again to update the list."
    }

    static func verifyFailed(_ message: String) -> String {
        "The file could not be checked again, so it was not moved. \(message)"
    }

    static func verifyDifferent(_ signature: String) -> String {
        "The file now matches a different detection (\(signature)) than the scan reported, so it was not moved. "
            + "Scan again to update the list."
    }

    static func moved(_ name: String) -> String {
        "\(name) was moved to the quarantine folder. You can restore it from the list below."
    }

    static func restored(_ path: String, signature: String?) -> String {
        guard let signature else { return "Restored to \(path)." }
        return "Restored to \(path). It was flagged as \(signature), so be careful with it."
    }

    static func unclaimed(_ count: Int) -> String {
        let noun = count == 1 ? "item" : "items"
        return "The quarantine folder holds \(count) \(noun) with no record. They were left untouched."
    }
}
