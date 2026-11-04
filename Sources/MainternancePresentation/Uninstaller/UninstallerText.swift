import Foundation
import MainternanceDomain

/// Every user-visible Uninstaller string, pinned by tests. Sizes are "about" (allocated space) or "at least" (part
/// was unreadable); leftovers are "found by identifier" or "matched by name only", never "safe" or "all traces".
enum UninstallerText {
    static let title = "Uninstaller"
    static let intro = "Apps in /Applications and ~/Applications, and what they left in your Library. "
        + "Nothing moves until you review it."
    static let searchPrompt = "Search apps"
    static let listing = "Looking for apps…"
    static let loadingDetails = "Measuring…"
    static let noApps = "No apps found"
    static let noMatch = "No app matches your search."
    static let selectApp = "Select an app"
    static let selectAppDetail = "Pick an app to see what it left in your Library."
    static let quitFirst = "Quit it first: an app that is open cannot be moved."
    static let identifierHeader = "Found by identifier"
    static let nameOnlyHeader = "Matched by name only — check these"
    static let launchAgentHeader = "Starts at login"
    static let launchAgentWarning = "Starts something at login; switch it off in Startup first."
    static let nothingLeft = "No leftovers were found for this app."
    static let appCardNote = "The app itself"
    static let review = "Review…"
    static let reviewTitle = "Move to the Trash?"
    static let reviewNote = "These items move to the Trash. Space comes back when you empty the Trash."
    static let confirm = "Confirm"
    static let cancel = "Cancel"
    static let moving = "Moving to the Trash…"
    static let trashNote = "Space comes back when you empty the Trash."
    static let nothingMoved = "Nothing was moved."
    static let skipped = "skipped because the app was not moved."

    static func size(_ bytes: Int64, lowerBound: Bool) -> String {
        "\(lowerBound ? "at least" : "about") \(formatBytes(bytes))"
    }

    static func size(_ leftover: Leftover) -> String {
        size(leftover.bytes, lowerBound: leftover.isLowerBound)
    }

    static func size(_ details: AppDetails) -> String {
        size(details.appBytes, lowerBound: details.appIsLowerBound)
    }

    /// The row's second line: the Library folder and the cleaned name, never the raw name.
    static func subtitle(_ leftover: Leftover) -> String {
        "~/Library/\(DisplayText.clean(leftover.location))/\(leftover.displayName)"
    }

    static func appTitle(_ app: InstalledApp) -> String {
        guard let version = app.version.map(DisplayText.clean), !version.isEmpty else { return app.displayName }
        return "\(app.displayName) \(version)"
    }

    /// The app's folder as shown (the review's second line): cleaned, never the raw path.
    static func appPath(_ app: InstalledApp) -> String {
        DisplayText.clean(app.id)
    }

    static func selected(_ bytes: Int64, lowerBound: Bool) -> String {
        "Selected: \(size(bytes, lowerBound: lowerBound))"
    }

    static func items(_ count: Int) -> String {
        count == 1 ? "1 item" : "\(count) items"
    }

    static func header(_ match: LeftoverMatch) -> String {
        switch match {
        case .identifier: identifierHeader
        case .nameOnly: nameOnlyHeader
        case .launchAgent: launchAgentHeader
        }
    }

    /// "Moved N items, about X, to the Trash." plus how many could not be moved; only moved bytes count.
    static func result(_ outcome: UninstallOutcome, lowerBound: Bool) -> String {
        let count = (outcome.appMoved ? 1 : 0) + outcome.movedLeftovers.count
        guard count > 0 else { return nothingMoved }
        let partial = lowerBound || outcome.movedLeftovers.contains(where: \.isLowerBound)
        let moved = "Moved \(items(count)), \(size(outcome.movedBytes, lowerBound: partial)), to the Trash."
        let failed = outcome.failedLeftovers.count
        return failed == 0 ? moved : "\(moved) \(failed) could not be moved."
    }

    static func failureLines(_ outcome: UninstallOutcome, appName: String) -> [String] {
        var lines: [String] = []
        if let reason = outcome.appFailure {
            lines.append("\(appName): not moved. \(DisplayText.clean(reason))")
        }
        lines += outcome.failedLeftovers.map { "\($0.leftover.displayName): \(DisplayText.clean($0.reason))" }
        lines += outcome.skipped.map { "\($0.displayName): \(skipped)" }
        return lines
    }
}
