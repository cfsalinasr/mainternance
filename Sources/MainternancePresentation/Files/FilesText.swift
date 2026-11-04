import Foundation
import MainternanceDomain

/// Every user-visible Files string, pinned by tests. Sizes are "about" (allocated space) or "at least" (some folders
/// could not be read). Nothing here says a file is "safe" to remove.
enum FilesText {
    static let title = "Files"
    static let searchPrompt = "Search by name"
    static let spotlightNote = "Spotlight results: files Spotlight has not indexed will not appear. Files only."
    static let spotlightUnavailable = "Spotlight did not answer"
    static let searching = "Searching…"
    static let noMatches = "No files found"
    static let truncated = "More files match than are shown. Add a filter to narrow the search."
    static let typeAny = "Any type"
    static let quickLook = "Quick Look"
    static let reveal = "Reveal in Finder"

    static let largeIntro = "Plain files of at least 50 MB in your home folder, largest first. "
        + "Your Library folder and hidden folders are not included."
    static let scan = "Scan"
    static let scanAgain = "Scan again"
    static let stop = "Stop"
    static let notScanned = "Not scanned yet"
    static let noLargeFiles = "No large files found"
    static let nothingToShow = "Nothing to show"

    static let staleMap = "The map was drawn before your last move. Scan again to update it."
    static let trash = "Move to the Trash"
    static let cancel = "Cancel"
    static let keep = "Keep"
    static let wouldRemove = "Would remove"
    static let keepLabel = "Keep:"
    static let duplicatesIntro = "Plain files of at least 1 MB in your home folder with exactly the same contents. "
        + "Your Library folder, hidden folders and files stored only in iCloud are not included."
    static let noDuplicates = "No duplicates found"
    static let duplicatesNotScanned = "Not scanned yet"
    static let duplicatesStopped = "The search stopped early, so more duplicates may exist."
    static let cloneNote = "Clones share disk space, so moving one may free less than shown."
    static let reviewTitle = "Move these files to the Trash?"
    static let reviewNote = "These files move to the Trash. Space comes back when you empty the Trash. " + cloneNote
    static let resultTitle = "Last move"

    static func reviewButton(count: Int, bytes: Int64) -> String {
        "Review \(count.formatted()) \(count == 1 ? "file" : "files"), frees about \(formatBytes(bytes))"
    }

    static func reviewSummary(count: Int, bytes: Int64) -> String {
        "\(count.formatted()) \(count == 1 ? "file" : "files"), about \(formatBytes(bytes))"
    }

    static func copies(_ count: Int, each bytes: Int64) -> String {
        "\(count.formatted()) copies, about \(formatBytes(bytes)) each"
    }

    static func frees(_ bytes: Int64) -> String {
        "Frees about \(formatBytes(bytes))"
    }

    /// Counts only what really moved.
    static func result(_ outcome: FileTrashOutcome) -> String {
        let count = outcome.moved.count
        var text = count == 0
            ? "Nothing was moved."
            : "Moved \(count.formatted()) \(count == 1 ? "file" : "files"), about \(formatBytes(outcome.movedBytes)), "
            + "to the Trash. " + cloneNote
        if !outcome.failed.isEmpty {
            text += " \(outcome.failed.count.formatted()) could not be moved."
        }
        return text
    }

    static func failure(_ failure: FileFailure) -> String {
        "\(failure.file.displayName): \(failure.reason)"
    }

    static func scanned(_ count: Int) -> String {
        "Scanned \(count.formatted()) \(count == 1 ? "file" : "files")"
    }

    static func unreadable(_ count: Int) -> String {
        "\(count.formatted()) \(count == 1 ? "folder" : "folders") could not be read"
    }

    static func total(_ bytes: Int64, lowerBound: Bool) -> String {
        "\(lowerBound ? "at least" : "about") \(formatBytes(bytes))"
    }
}

extension FileKind {
    var title: String {
        switch self {
        case .document: "Documents"
        case .image: "Images"
        case .video: "Videos"
        case .audio: "Audio"
        case .archive: "Archives"
        case .code: "Code"
        case .other: "Other"
        }
    }

    var symbol: String {
        switch self {
        case .document: "doc.text"
        case .image: "photo"
        case .video: "film"
        case .audio: "waveform"
        case .archive: "archivebox"
        case .code: "chevron.left.forwardslash.chevron.right"
        case .other: "doc"
        }
    }
}
