import Foundation
import MainternanceDomain

/// Every user-visible Cleanup string, pinned by tests. Plain descriptions of what is where and how big it is;
/// never "safe", "junk" or "boost". Sizes are always "about" (allocated space) or "at least" (part was unreadable).
enum CleanupText {
    static let title = "Cleanup"
    static let intro = "Caches, logs, old installers and Xcode build caches in your home folder. "
        + "Nothing moves until you review it."
    static let measuring = "Measuring…"
    static let measureAgain = "Measure again"
    static let review = "Review"
    static let reviewTitle = "Move to the Trash?"
    static let reviewNote = [
        "These items move to the Trash. Space comes back when you empty the Trash.",
        "Quit apps before cleaning their caches."
    ].joined(separator: " ")
    static let moveToTrash = "Move to Trash"
    static let cancel = "Cancel"
    static let moving = "Moving to the Trash…"
    static let nothingFound = "Nothing to clean was found in these folders."
    static let emptyCategory = "Nothing here."
    static let nothingMoved = "Nothing was moved. The reasons are listed below."
    static let trashNote = "Space comes back when you empty the Trash."
    static let quitAppsNote = "Quit apps before cleaning their caches: a cache in use may not move."

    static func title(_ kind: CleanupKind) -> String {
        switch kind {
        case .caches: "Caches"
        case .logs: "Logs"
        case .installers: "Old installers"
        case .developer: "Developer build caches"
        }
    }

    static func detail(_ kind: CleanupKind) -> String {
        switch kind {
        case .caches: "Files apps keep to start faster; they are made again when needed."
        case .logs: "Diagnostic records apps and macOS wrote."
        case .installers: "Disk images and packages in Downloads not changed for more than 30 days."
        case .developer: "Xcode's DerivedData; Xcode builds it again when needed."
        }
    }

    static func symbol(_ kind: CleanupKind) -> String {
        switch kind {
        case .caches: "internaldrive"
        case .logs: "doc.text"
        case .installers: "shippingbox"
        case .developer: "hammer"
        }
    }

    /// Where the category's entries live, as shown.
    static func folder(_ kind: CleanupKind) -> String {
        switch kind {
        case .caches: "~/Library/Caches"
        case .logs: "~/Library/Logs"
        case .installers: "~/Downloads"
        case .developer: "~/Library/Developer/Xcode/DerivedData"
        }
    }

    static func size(_ bytes: Int64, lowerBound: Bool) -> String {
        "\(lowerBound ? "at least" : "about") \(formatBytes(bytes))"
    }

    static func size(_ category: CleanupCategory) -> String {
        size(category.bytes, lowerBound: category.isLowerBound)
    }

    static func size(_ entry: CleanupEntry) -> String {
        size(entry.bytes, lowerBound: entry.isLowerBound)
    }

    /// The entry's folder and cleaned name: never the raw name, which can hold line breaks or bidi characters.
    static func shortPath(_ entry: CleanupEntry, kind: CleanupKind) -> String {
        "\(folder(kind))/\(entry.displayName)"
    }

    static func type(_ type: CleanupEntry.ItemType) -> String {
        switch type {
        case .file: "File"
        case .directory: "Folder"
        case .symbolicLink: "Link (only the link moves)"
        }
    }

    /// The review row's second line: where it is and what it is.
    static func subtitle(_ entry: CleanupEntry, kind: CleanupKind) -> String {
        "\(shortPath(entry, kind: kind)) · \(type(entry.type))"
    }

    static func unreadable(_ kind: CleanupKind) -> String {
        "Could not open \(folder(kind)), so it is not measured."
    }

    static func selected(_ bytes: Int64, lowerBound: Bool) -> String {
        "Selected: \(size(bytes, lowerBound: lowerBound))"
    }

    static func items(_ count: Int) -> String {
        count == 1 ? "1 item" : "\(count) items"
    }

    /// "Moved N items, about X, to the Trash." plus how many could not be moved; only moved bytes count.
    static func result(_ outcome: CleanupOutcome) -> String {
        let moved = "Moved \(items(outcome.moved.count)), about \(formatBytes(outcome.movedBytes)), to the Trash."
        return outcome.failed.isEmpty ? moved : "\(moved) \(outcome.failed.count) could not be moved."
    }

    static func failure(_ failure: CleanupFailure) -> String {
        "\(failure.entry.displayName): \(failure.reason)"
    }
}
