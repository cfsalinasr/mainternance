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
    static let installStarting = "Starting the install…"
    static let updateStarting = "Downloading definitions…"
    static let checkingFile = "Checking the file again before moving it…"
    static let quarantineTitle = "Quarantine this file?"
    static let quarantineHeading = "Quarantine"
    static let scanning = "Scanning…"
    static let detectedBadge = "Detected"
    static let notMovedBadge = "Not moved"
    static let quarantinedBadge = "Quarantined"
    static let quickButton = "Quick scan"
    static let fullButton = "Full scan"
    static let cancelButton = "Cancel"
    static let installButton = "Install"
    static let updateButton = "Update definitions"
    static let checkAgainButton = "Check again"
    static let quarantineButton = "Quarantine…"
    static let confirmButton = "Quarantine"
    static let restoreButton = "Restore"
    static let cancelScanLabel = "Cancel scan"
    static let installHint = "Installs the ClamAV scanning engine with Homebrew"
    static let updateHint = "Downloads the latest virus definitions"
    static let quarantineHint = "Asks for confirmation first"
    static let restoreHint = "Puts the file back where it came from"
    static let fullDiskAccessHint = "Opens System Settings, where you can allow Mainternance to read all files"

    static func findingsHeading(_ count: Int) -> String {
        "Findings (\(count))"
    }

    static func detectionLine(_ signature: String) -> String {
        "Detection: \(signature)"
    }

    static func quarantineLabel(_ name: String) -> String {
        "Quarantine \(name)"
    }

    static func restoreLabel(_ name: String) -> String {
        "Restore \(name)"
    }

    static let savedResultsUnreadable = "The scanner's saved results could not be read."
    static let lastScanDidNotFinish = [
        "The last scan did not finish (the app was closed or stopped during it), so its results are incomplete.",
        "Run a scan again."
    ].joined(separator: " ")
    static let scanEndedWithoutResult = "The scan ended without a result. Run it again."
    static let protectedFolder =
        "That folder holds the app's own quarantine or scanner data, so it cannot be scanned."

    // MARK: - Counts

    static func files(_ count: Int, locale: Locale = .current) -> String {
        let value = max(0, count)
        return "\(value.formatted(.number.locale(locale))) \(value == 1 ? "file" : "files")"
    }

    /// Plural-aware: "1 detection could not be attributed to a file (unusual file names). The scan is not clean."
    /// and "3 detections could ...".
    static func unattributed(_ count: Int) -> String {
        let value = max(0, count)
        let noun = value == 1 ? "detection" : "detections"
        return "\(value) \(noun) could not be attributed to a file (unusual file names). The scan is not clean."
    }

    /// Plural-aware ("1 detection", "3 detections"); shown when a cancelled or failed scan could not attribute
    /// detections to a file. Names exactly what clears the count: a completed full scan, or a completed scan of the
    /// same scope, with no unattributed detections of its own. Mixed scopes are stored as full.
    static func unattributedIncomplete(_ count: Int, scope: ScanScope?) -> String {
        let value = max(0, count)
        let noun = value == 1 ? "detection" : "detections"
        let clearedBy = switch scope {
        case .quick: "a full scan, or another quick scan,"
        case let .custom(url): "a full scan, or another scan of \(url.path),"
        case .full, nil: "a full scan"
        }
        return "\(value) \(noun) from a scan that did not finish could not be attributed to a file "
            + "(unusual file names). It stays counted until \(clearedBy) finishes without such detections."
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
}
