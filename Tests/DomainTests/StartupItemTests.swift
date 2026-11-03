import Foundation
import MainternanceDomain
import Testing

@Suite("Startup items")
struct StartupItemTests {
    @Test("a label that could be read as an option, a path or several lines never counts as valid", arguments: [
        "", "--version", "-h", "../x", "a/b", "/abs", "line\nbreak", "tab\there", "nul\u{0}", "bell\u{7}",
        "zero\u{200B}width", "bidi\u{202E}override", "sep\u{2028}line", ".", "..", String(repeating: "a", count: 256),
        String(repeating: "é", count: 128)
    ])
    func invalidLabels(_ label: String) {
        #expect(!StartupItem.isValidLabel(label))
    }

    @Test("ordinary reverse-DNS labels are valid, up to 255 bytes", arguments: [
        "com.example.updater", "S8EX82NJP6.com.macpaw.CleanMyMac-mas.HealthMonitor", "a", "with space",
        "x-y_z.1", String(repeating: "a", count: 255)
    ])
    func validLabels(_ label: String) {
        #expect(StartupItem.isValidLabel(label))
    }

    @Test("the name is the label's last component, or the file name when there is no label")
    func names() {
        let agent = StartupItem(
            kind: .userAgent,
            plistPath: "/x/com.example.updater.plist",
            label: "com.example.updater"
        )
        #expect(agent.name == "updater")
        #expect(agent.id == "/x/com.example.updater.plist")
        let unlabeled = StartupItem(kind: .userAgent, plistPath: "/x/Mystery Thing.plist")
        #expect(unlabeled.name == "Mystery Thing")
        let trailingDot = StartupItem(kind: .userAgent, plistPath: "/x/a.plist", label: "odd.")
        #expect(trailingDot.name == "odd.")
        let plain = StartupItem(kind: .userAgent, plistPath: "/x/a.plist", label: "single")
        #expect(plain.name == "single")
    }

    @Test("only a readable user agent with a valid label can be switched")
    func canToggle() {
        let path = "/x/a.plist"
        #expect(StartupItem(kind: .userAgent, plistPath: path, label: "com.a").canToggle)
        #expect(!StartupItem(kind: .systemAgent, plistPath: path, label: "com.a").canToggle)
        #expect(!StartupItem(kind: .systemDaemon, plistPath: path, label: "com.a").canToggle)
        #expect(!StartupItem(kind: .userAgent, plistPath: path).canToggle)
        #expect(!StartupItem(kind: .userAgent, plistPath: path, label: "--version").canToggle)
        #expect(!StartupItem(kind: .userAgent, plistPath: path, label: "com.a", readProblem: "bad").canToggle)
    }

    @Test("the review key is a valid label, or else the file path; the two never collide")
    func reviewKeys() {
        let labeled = StartupItem(kind: .userAgent, plistPath: "/x/a.plist", label: "com.a")
        let unlabeled = StartupItem(kind: .userAgent, plistPath: "/x/a.plist")
        let invalid = StartupItem(kind: .userAgent, plistPath: "/x/a.plist", label: "/x/a.plist")
        #expect(labeled.reviewKey == "label:com.a")
        #expect(unlabeled.reviewKey == "path:/x/a.plist")
        #expect(invalid.reviewKey == "path:/x/a.plist")
        #expect(labeled.reviewKey != unlabeled.reviewKey)
    }

    @Test("an item is reviewed when its key, or its path from a time it was keyed by path, is in the baseline")
    func reviewedByLabelOrEarlierPath() {
        let now = StartupItem(kind: .userAgent, plistPath: "/x/a.plist", label: "com.a")
        #expect(now.isReviewed(in: ["label:com.a"]))
        #expect(now.isReviewed(in: ["path:/x/a.plist"])) // it could not be read when the baseline was written
        #expect(!now.isReviewed(in: ["path:/x/b.plist", "label:com.b"]))
        let unreadable = StartupItem(kind: .userAgent, plistPath: "/x/a.plist", readProblem: "bad")
        #expect(unreadable.isReviewed(in: ["path:/x/a.plist"]))
        #expect(!unreadable.isReviewed(in: ["label:com.a"]))
    }

    @Test("text shown from a plist has no bidi, zero-width or control characters; the label itself is untouched")
    func displayTextIsSanitized() {
        let label = "com.evil.\u{202E}gpj\u{200B}up\u{0007}date"
        let item = StartupItem(
            kind: .userAgent, plistPath: "/x/a.plist", label: label, program: "/bin/\u{2066}tool\u{2069}\nnext"
        )
        #expect(item.label == label)
        #expect(item.name == "gpjupdate")
        #expect(item.displayLabel == "com.evil.gpjupdate")
        #expect(item.displayProgram == "/bin/tool next")
        #expect(StartupItem.displayText("plain text") == "plain text")
        #expect(StartupItem.displayText("tab\there\u{2028}x") == "tab here x")
        let blank = StartupItem(kind: .userAgent, plistPath: "/x/Fallback.plist", label: "\u{202E}\u{200B}")
        #expect(blank.name == "Fallback") // nothing visible left: the file name
        let file = StartupItem(kind: .userAgent, plistPath: "/x/odd\u{202E}name.plist")
        #expect(file.name == "oddname")
        #expect(StartupItem(kind: .userAgent, plistPath: "/x/a.plist").displayProgram == nil)
    }

    @Test("the plist's own Disabled key is kept, false when it does not say")
    func disabledInFile() {
        #expect(StartupItem(kind: .userAgent, plistPath: "/x/a.plist", disabledInFile: true).disabledInFile)
        #expect(!StartupItem(kind: .userAgent, plistPath: "/x/a.plist").disabledInFile)
    }

    @Test("a fresh item has an unknown state and is not new")
    func defaults() {
        let item = StartupItem(kind: .systemDaemon, plistPath: "/x/a.plist", label: "com.a")
        #expect(item.isEnabled == nil)
        #expect(!item.isNew)
        #expect(item.readProblem == nil)
        #expect(StartupKind.allCases == [.userAgent, .systemAgent, .systemDaemon])
    }

    @Test("errors read as plain sentences")
    func errorText() {
        #expect(StartupError.notAllowed.errorDescription == "Only your own agents can be switched here. "
            + "This one is installed for all users: change it in the app that installed it.")
        #expect(StartupError.unreadable.errorDescription
            == "This item's file could not be read, so nothing was changed.")
        #expect(StartupError.invalidLabel.errorDescription?.contains("label") == true)
        #expect(StartupError.failed("Operation not permitted").errorDescription
            == "macOS could not change it: Operation not permitted")
    }

    @Test("an empty snapshot claims nothing")
    func emptySnapshot() {
        let snapshot = StartupSnapshot()
        #expect(snapshot.items.isEmpty)
        #expect(!snapshot.baselineEstablished)
        #expect(snapshot.newCount == nil)
        #expect(snapshot.duplicateLabels.isEmpty)
        #expect(snapshot.unreadableFolders.isEmpty)
        #expect(!snapshot.reviewUnreadable)
        #expect(!snapshot.reviewReadOnly)
    }
}
