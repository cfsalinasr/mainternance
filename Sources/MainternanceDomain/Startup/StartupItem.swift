import Foundation

/// Where a launchd job is registered, which decides who it runs for and who may change it.
public enum StartupKind: Sendable, CaseIterable {
    /// `~/Library/LaunchAgents`: runs for this user only; the owner can switch it off and on.
    case userAgent
    /// `/Library/LaunchAgents`: runs for every user who logs in; read-only here by design.
    case systemAgent
    /// `/Library/LaunchDaemons`: runs as part of the system; read-only here by design.
    case systemDaemon
}

/// One launchd property list file and what it registers. Everything read from the file is untrusted text: it is
/// shown, never executed, and the label is checked with `isValidLabel` before it is ever passed to `launchctl`.
/// What is shown (`name`, `displayLabel`, `displayProgram`) has bidi, zero-width and control characters removed;
/// `label` and `plistPath` stay exactly as read.
public struct StartupItem: Sendable, Equatable, Identifiable {
    /// The property list's path: one row per file, even when two files share a label.
    public let id: String
    /// The `Label` key; nil when the file has none (or it is not text).
    public let label: String?
    /// The label's last component ("com.example.updater" -> "updater"), or the file name without `.plist`;
    /// display text only (see `displayText`).
    public let name: String
    public let kind: StartupKind
    public let plistPath: String
    /// `Program`, or else the first entry of `ProgramArguments`; nil when the file names neither.
    public let program: String?
    /// The `RunAtLoad` key; nil when the file does not say.
    public let runsAtLoad: Bool?
    /// What launchd reports; nil when that could not be read ("Unknown"), never guessed.
    public var isEnabled: Bool?
    /// Not present at the owner's last review.
    public var isNew: Bool
    /// Why the file could not be read; nil when it was read.
    public let readProblem: String?
    /// The plist's own `Disabled` key is true. launchd uses it when it has no override of its own for the label.
    public let disabledInFile: Bool

    public init(
        kind: StartupKind, plistPath: String, label: String? = nil, program: String? = nil,
        runsAtLoad: Bool? = nil, readProblem: String? = nil, disabledInFile: Bool = false
    ) {
        id = plistPath
        self.label = label
        name = Self.displayName(label: label, plistPath: plistPath)
        self.kind = kind
        self.plistPath = plistPath
        self.program = program
        self.runsAtLoad = runsAtLoad
        isEnabled = nil
        isNew = false
        self.readProblem = readProblem
        self.disabledInFile = disabledInFile
    }

    /// The label as shown; nil when there is none.
    public var displayLabel: String? {
        label.map(Self.displayText)
    }

    /// The program as shown; nil when the file names none.
    public var displayProgram: String? {
        program.map(Self.displayText)
    }

    /// Only the owner's own agents can be switched (no administrator needed), and only when the file was read and
    /// its label is safe to pass to `launchctl`.
    public var canToggle: Bool {
        kind == .userAgent && readProblem == nil && label.map(Self.isValidLabel) == true
    }

    /// What the review baseline remembers: the label when it is valid, or else the file path. The prefixes keep a
    /// label from ever matching a path.
    public var reviewKey: String {
        if let label, Self.isValidLabel(label) {
            return "label:\(label)"
        }
        return pathReviewKey
    }

    var pathReviewKey: String {
        "path:\(plistPath)"
    }

    /// Present at the review that saved `seen`: under its key, or under its path (it was keyed by path then, for
    /// example because the file could not be read).
    public func isReviewed(in seen: Set<String>) -> Bool {
        seen.contains(reviewKey) || seen.contains(pathReviewKey)
    }

    /// A label may be passed to `launchctl` only when it is non-empty, at most 255 bytes, has no `/`, does not
    /// start with `-` (it could be read as an option), is not `.` or `..`, and has no control, format or line
    /// separator characters.
    public static func isValidLabel(_ text: String) -> Bool {
        guard !text.isEmpty, text.utf8.count <= 255, !text.hasPrefix("-"), !text.contains("/"),
              text != ".", text != ".."
        else { return false }
        let forbidden = CharacterSet.controlCharacters.union(.newlines).union(.illegalCharacters)
        return !text.unicodeScalars.contains { forbidden.contains($0) }
    }

    /// `text` without control, format (bidi, zero-width) or illegal characters; tabs and line breaks become
    /// spaces. For showing untrusted text only, never for what is passed to `launchctl`.
    public static func displayText(_ text: String) -> String {
        DisplayText.clean(text)
    }

    static func displayName(label: String?, plistPath: String) -> String {
        if let shown = label.map(displayText), !shown.isEmpty {
            let last = shown.split(separator: ".").last.map(String.init) ?? shown
            return shown.hasSuffix(".") ? shown : last
        }
        let file = displayText((plistPath as NSString).lastPathComponent)
        return file.hasSuffix(".plist") ? String(file.dropLast(".plist".count)) : file
    }
}

/// One reading of everything that starts at login or boot.
public struct StartupSnapshot: Sendable, Equatable {
    public var items: [StartupItem]
    /// False until a review baseline existed before this reading (the first reading only creates it).
    public var baselineEstablished: Bool
    /// How many items are new since the last review; nil while there is no baseline or it could not be read.
    public var newCount: Int?
    /// Labels registered by more than one file.
    public var duplicateLabels: Set<String>
    /// launchd folders that exist but could not be opened, so their items are missing from `items`.
    public var unreadableFolders: [String]
    /// The saved review could not be read (or a damaged one could not be moved aside): nothing is marked new.
    public var reviewUnreadable: Bool
    /// The review cannot be saved (its folder cannot be written, or writing it failed): nothing is marked new and
    /// Mark all as reviewed is not offered.
    public var reviewReadOnly: Bool

    public init(
        items: [StartupItem] = [], baselineEstablished: Bool = false, newCount: Int? = nil,
        duplicateLabels: Set<String> = [], unreadableFolders: [String] = [], reviewUnreadable: Bool = false,
        reviewReadOnly: Bool = false
    ) {
        self.items = items
        self.baselineEstablished = baselineEstablished
        self.newCount = newCount
        self.duplicateLabels = duplicateLabels
        self.unreadableFolders = unreadableFolders
        self.reviewUnreadable = reviewUnreadable
        self.reviewReadOnly = reviewReadOnly
    }
}
