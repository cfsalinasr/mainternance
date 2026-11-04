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
