import Foundation
import Observation

enum ScannerEngineState: Equatable {
    case notInstalled
    case installing(progress: Double)
    case downloadingDefinitions(progress: Double)
    case ready(definitionsAge: Duration)
    case updateNeeded

    var title: String {
        switch self {
        case .notInstalled: "Scanning engine not installed"
        case .installing: "Installing…"
        case .downloadingDefinitions: "Downloading definitions…"
        case .ready: "Engine ready"
        case .updateNeeded: "Definitions out of date"
        }
    }

    var detail: String {
        switch self {
        case .notInstalled: "Install the open-source ClamAV engine to scan for malware."
        case .installing: "Setting up the scanning engine."
        case .downloadingDefinitions: "Fetching the latest threat definitions."
        case let .ready(age): "Definitions updated \(Self.ageText(age)) ago."
        case .updateNeeded: "Update the definitions before scanning."
        }
    }

    /// Fraction for the determinate bar; nil when no operation is in flight.
    var progress: Double? {
        switch self {
        case let .installing(progress), let .downloadingDefinitions(progress): ScannerProgress.clamp(progress)
        default: nil
        }
    }

    var symbol: String {
        switch self {
        case .notInstalled: "shield.slash"
        case .installing, .downloadingDefinitions: "arrow.down.circle"
        case .ready: "checkmark.shield"
        case .updateNeeded: "exclamationmark.triangle"
        }
    }

    /// Scan buttons are enabled only when the engine is ready.
    var canScan: Bool {
        if case .ready = self {
            return true
        }
        return false
    }

    static func ageText(_ age: Duration) -> String {
        let seconds = max(age.components.seconds, 0)
        if seconds < 3600 {
            return "less than an hour"
        }
        return age.formatted(.units(allowed: [.days, .hours], width: .wide, maximumUnitCount: 1))
    }
}

enum ScanRunState: Equatable {
    case idle
    case running(scanned: Int, current: String)
    case finished(findings: Int)

    var title: String {
        switch self {
        case .idle: "No scan running"
        case .running: "Scanning…"
        case let .finished(findings): findings == 0 ? "No threats found" : "Scan finished"
        }
    }

    var detail: String {
        switch self {
        case .idle: "Start a quick or full scan."
        case let .running(scanned, _): "\(max(scanned, 0).formatted()) files scanned"
        case let .finished(findings):
            findings == 0
                ? "Your Mac looks clean."
                : "\(findings) \(findings == 1 ? "item" : "items") need your attention."
        }
    }
}

enum ScannerProgress {
    /// Out-of-range and NaN input never reach the progress bar.
    static func clamp(_ value: Double) -> Double {
        value.isNaN ? 0 : min(max(value, 0), 1)
    }
}

enum FindingSeverity: Int, Equatable {
    case low, medium, high

    var title: String {
        switch self {
        case .low: "Low"
        case .medium: "Medium"
        case .high: "High"
        }
    }

    var symbol: String {
        switch self {
        case .low: "info.circle"
        case .medium: "exclamationmark.triangle"
        case .high: "exclamationmark.octagon"
        }
    }
}

struct ScanFinding: Identifiable, Equatable {
    let id: String
    let name: String
    let path: String
    let reason: String
    let severity: FindingSeverity
}

struct ScanSchedule: Equatable {
    /// 1 = Sunday, matching `Calendar`.
    var weekday = 1
    var hour = 2
    var minute = 0

    /// The calendar's name for a weekday (1 = Sunday); empty when out of range.
    static func weekdayName(_ weekday: Int, calendar: Calendar) -> String {
        let names = calendar.weekdaySymbols
        return names.indices.contains(weekday - 1) ? names[weekday - 1] : ""
    }

    /// "Weekly, Sunday 02:00"; the clock follows the locale (12 h or 24 h).
    func description(locale: Locale = .current, timeZone: TimeZone = .current) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = locale
        calendar.timeZone = timeZone
        let day = Self.weekdayName(weekday, calendar: calendar)
        let time = calendar.date(from: DateComponents(hour: hour, minute: minute))
            .map {
                $0.formatted(Date.FormatStyle(locale: locale, calendar: calendar, timeZone: timeZone).hour().minute())
            } ?? ""
        return "Weekly, \(day) \(time)"
    }
}

enum ScannerSampleData {
    static let findings: [ScanFinding] = [
        ScanFinding(
            id: "launch-agent",
            name: "com.update.helper.plist",
            path: "~/Library/LaunchAgents/com.update.helper.plist",
            reason: "Unsigned launch agent that starts at login",
            severity: .medium
        ),
        ScanFinding(
            id: "adware-installer",
            name: "FlashPlayerInstaller.dmg",
            path: "~/Downloads/FlashPlayerInstaller.dmg",
            reason: "Matches a known adware signature",
            severity: .high
        ),
        ScanFinding(
            id: "browser-helper",
            name: "SearchHelper.app",
            path: "~/Applications/SearchHelper.app",
            reason: "Unsigned app that changes browser settings",
            severity: .low
        )
    ]
}

/// One entry of the "Design preview" picker; removed in the scanner-engine plan.
struct ScannerPreview: Identifiable, Equatable {
    let id: String
    let title: String
    let engine: ScannerEngineState
    let run: ScanRunState

    static let all: [ScannerPreview] = [
        ScannerPreview(id: "not-installed", title: "Not installed", engine: .notInstalled, run: .idle),
        ScannerPreview(id: "installing", title: "Installing", engine: .installing(progress: 0.4), run: .idle),
        ScannerPreview(
            id: "downloading",
            title: "Downloading definitions",
            engine: .downloadingDefinitions(progress: 0.7),
            run: .idle
        ),
        ScannerPreview(
            id: "ready-idle",
            title: "Ready, idle",
            engine: .ready(definitionsAge: .seconds(3 * 3600)),
            run: .idle
        ),
        ScannerPreview(
            id: "ready-running",
            title: "Ready, scanning",
            engine: .ready(definitionsAge: .seconds(3 * 3600)),
            run: .running(scanned: 18432, current: "/Users/sample/Library/Application Support/Example/Caches/Deep")
        ),
        ScannerPreview(
            id: "ready-findings",
            title: "Ready, 3 findings",
            engine: .ready(definitionsAge: .seconds(3 * 3600)),
            run: .finished(findings: 3)
        ),
        ScannerPreview(
            id: "ready-clean",
            title: "Ready, no threats",
            engine: .ready(definitionsAge: .seconds(3 * 3600)),
            run: .finished(findings: 0)
        ),
        ScannerPreview(id: "update-needed", title: "Definitions out of date", engine: .updateNeeded, run: .idle)
    ]
}

@MainActor
@Observable
public final class ScannerViewState {
    private(set) var engine: ScannerEngineState
    private(set) var run: ScanRunState
    private(set) var previewID: String
    private(set) var quarantined: Set<String> = []
    /// The finding awaiting confirmation in the quarantine sheet.
    var pendingQuarantineID: String?

    let findings: [ScanFinding]
    private let scheduleStore: ScanScheduleStore

    public convenience init(schedule: ScanScheduleStore = ScanScheduleStore()) {
        self.init(findings: ScannerSampleData.findings, schedule: schedule)
    }

    init(findings: [ScanFinding] = ScannerSampleData.findings, schedule: ScanScheduleStore = ScanScheduleStore()) {
        self.findings = findings
        scheduleStore = schedule
        let first = ScannerPreview.all.first { $0.id == "ready-findings" } ?? ScannerPreview.all[0]
        engine = first.engine
        run = first.run
        previewID = first.id
    }

    /// The schedule line; follows the shared schedule, so a change in Settings shows here too.
    func scheduleSummary(locale: Locale = .current, timeZone: TimeZone = .current) -> String {
        scheduleStore.summary(locale: locale, timeZone: timeZone)
    }

    /// What the results area shows for the current run.
    enum ResultsContent: Equatable {
        case none, clean, findings
    }

    var resultsContent: ResultsContent {
        switch run {
        case .finished(findings: 0): .clean
        case .finished: .findings
        case .idle, .running: .none
        }
    }

    var pendingFinding: ScanFinding? {
        pendingQuarantineID.flatMap { id in findings.first { $0.id == id } }
    }

    func select(previewID id: String) {
        guard let preview = ScannerPreview.all.first(where: { $0.id == id }) else { return }
        previewID = id
        pendingQuarantineID = nil // A stale confirmation must not outlive the preview it was opened in.
        engine = preview.engine
        run = preview.run
    }

    func isQuarantined(_ id: String) -> Bool {
        quarantined.contains(id)
    }

    func requestQuarantine(_ id: String) {
        guard findings.contains(where: { $0.id == id }), !quarantined.contains(id) else { return }
        pendingQuarantineID = id
    }

    func cancelQuarantine() {
        pendingQuarantineID = nil
    }

    /// Sample state only; no file is touched or deleted.
    func confirmQuarantine() {
        if let id = pendingFinding?.id {
            quarantine(id)
        }
        pendingQuarantineID = nil
    }

    func quarantine(_ id: String) {
        guard findings.contains(where: { $0.id == id }) else { return }
        quarantined.insert(id)
    }

    func restore(_ id: String) {
        quarantined.remove(id)
    }
}
