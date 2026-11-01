import Foundation
import MainternanceDomain

/// Every user-visible sentence of the Scanner screen, as plain functions and constants so tests can pin them.
/// Nothing here claims the Mac is "safe" or "protected": it says what was scanned, what was found and what was not
/// checked.
enum ScannerText {
    static let caption = "Detections come from ClamAV signatures and can include false positives."
    static let quarantineExplanation =
        "The file will be moved to the app's quarantine folder. It is not deleted and you can restore it."
    static let fullDiskAccessURL =
        "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_AllFiles"
    static let fullDiskAccessButton = "Open Full Disk Access settings"
    static let homebrewURL = "https://brew.sh"
    static let notMovedNote = "could not be moved; still in its original place"
    static let cloudAdvisory = [
        "A full scan skips your iCloud Drive (~/Library/Mobile Documents) and cloud storage",
        "(~/Library/CloudStorage) folders, so files that only live there are not checked."
    ].joined(separator: " ")
    static let quickScope =
        "Quick scan: Downloads, Desktop, Applications and the Launch Agents and Launch Daemons folders."
    static let fullScope = "Full scan: your home folder and Applications."
    static let scanEndedWithoutResult = "The scan ended without a result. Run it again."
    static let protectedFolder =
        "That folder holds the app's own quarantine or scanner data, so it cannot be scanned."

    // MARK: - Counts

    static func files(_ count: Int, locale: Locale = .current) -> String {
        let value = max(0, count)
        return "\(value.formatted(.number.locale(locale))) \(value == 1 ? "file" : "files")"
    }

    /// Exactly: "N detection(s) could not be attributed to a file (unusual file names). The scan is not clean."
    static func unattributed(_ count: Int) -> String {
        let value = max(0, count)
        let noun = value == 1 ? "detection" : "detections"
        return "\(value) \(noun) could not be attributed to a file (unusual file names). The scan is not clean."
    }

    static func permissionExplanation(_ count: Int, locale: Locale = .current) -> String {
        [
            "\(files(count, locale: locale)) could not be read because macOS denied access.",
            "This usually means Mainternance does not have Full Disk Access. Those files were not scanned."
        ].joined(separator: " ")
    }

    // MARK: - Engine

    struct EngineCard: Equatable {
        var title: String
        var detail: String
        var symbol: String
    }

    static func engineCard(_ status: EngineStatus?, run: ScannerViewModel.RunState) -> EngineCard {
        if case let .installing(stage, _) = run {
            return EngineCard(title: stage, detail: "This can take a few minutes.", symbol: "arrow.down.circle")
        }
        guard let status else {
            return EngineCard(
                title: "Checking the scanning engine…", detail: "Looking for ClamAV on this Mac.",
                symbol: "magnifyingglass"
            )
        }
        switch status {
        case .homebrewMissing:
            return EngineCard(
                title: "Homebrew is needed",
                detail: "The scanner installs its engine (ClamAV) with Homebrew. Install Homebrew from \(homebrewURL), "
                    + "then press Check again.",
                symbol: "shield.slash"
            )
        case .notInstalled:
            return EngineCard(
                title: "Scanning engine not installed",
                detail: "Install the open-source ClamAV engine to scan for malware. "
                    + "This runs Homebrew (brew install clamav) and can take a few minutes.",
                symbol: "shield.slash"
            )
        case let .installing(stage):
            return EngineCard(title: stage, detail: "Setting up the scanning engine.", symbol: "arrow.down.circle")
        case .downloadingDefinitions:
            return EngineCard(
                title: "Downloading definitions…", detail: "Fetching the latest virus definitions.",
                symbol: "arrow.down.circle"
            )
        case let .ready(age):
            return EngineCard(title: "Engine ready", detail: definitionsAge(age), symbol: "checkmark.circle")
        case let .updateNeeded(age):
            return EngineCard(
                title: age == nil ? "No virus definitions yet" : "Definitions out of date",
                detail: age == nil
                    ? "Download the virus definitions before scanning."
                    : "\(definitionsAge(age)) Update them before you rely on a scan.",
                symbol: "exclamationmark.triangle"
            )
        case let .failed(message):
            return EngineCard(title: "The scanning engine has a problem", detail: message, symbol: "xmark.octagon")
        }
    }

    static func definitionsAge(_ age: TimeInterval?) -> String {
        guard let age, age.isFinite else { return "The age of the virus definitions is unknown." }
        return "Virus definitions updated \(ageText(age)) ago."
    }

    static func ageText(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds >= 3600 else { return "less than an hour" }
        let capped = min(seconds, 10 * 365 * 86400)
        return Duration.seconds(capped).formatted(.units(allowed: [.days, .hours], width: .wide, maximumUnitCount: 1))
    }

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
