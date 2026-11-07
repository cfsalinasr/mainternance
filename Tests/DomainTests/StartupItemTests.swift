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

    private func item(
        _ path: String = "/x/a.plist", label: String? = "com.a", fingerprint: String? = "p1", readProblem: String? = nil
    ) -> StartupItem {
        var item = StartupItem(kind: .userAgent, plistPath: path, label: label, readProblem: readProblem)
        item.programFingerprint = fingerprint
        return item
    }

    @Test("the review key holds the valid label, the file path and the program, so changing any one changes it")
    func reviewKeys() {
        let base = item()
        #expect(base.reviewKey == "item2\u{0}com.a\u{0}/x/a.plist\u{0}p1")
        #expect(item(label: "/x/a.plist")
            .reviewKey == "item2\u{0}\u{0}/x/a.plist\u{0}p1") // an invalid label is left out
        #expect(base.reviewKey != item(fingerprint: "p2").reviewKey)
        #expect(base.reviewKey != item("/x/b.plist").reviewKey)
        #expect(base.reviewKey != item(label: "com.b").reviewKey)
        #expect(base.reviewKey != item(label: nil).reviewKey)
    }

    @Test("an item reviewed as it is now is reviewed; another program under the same label or file is changed")
    func changedSinceReview() {
        let seen = StartupReviewBaseline([item().reviewKey])
        #expect(seen.match(item()) == .reviewed)
        #expect(seen.match(item(fingerprint: "evil")) == .changed) // the plist now runs something else
        #expect(seen.match(item("/x/replaced.plist")) == .changed) // another file took the label
        #expect(seen.match(item(label: "com.other")) == .changed) // the same file now registers another label
        #expect(seen.match(item("/x/b.plist", label: "com.b")) == .new)
    }

    @Test("an old-style key counts as reviewed once (to be upgraded); once upgraded it can never hide a change")
    func legacyKeysAreUpgradedOnce() {
        let now = item()
        #expect(StartupReviewBaseline(["label:com.a"]).match(now) == .reviewedBeforeUpgrade)
        #expect(StartupReviewBaseline(["path:/x/a.plist"]).match(now) == .reviewedBeforeUpgrade)
        #expect(StartupReviewBaseline(["path:/x/b.plist", "label:com.b"]).match(now) == .new)
        let unreadable = item(label: nil, fingerprint: nil, readProblem: "bad")
        #expect(StartupReviewBaseline(["path:/x/a.plist"]).match(unreadable) == .reviewedBeforeUpgrade)
        #expect(StartupReviewBaseline(["label:com.a"]).match(unreadable) == .new)
        // Upgraded, with the old key left behind: a new program is still flagged.
        let upgraded = StartupReviewBaseline(["label:com.a", now.reviewKey])
        #expect(upgraded.match(item(fingerprint: "evil")) == .changed)
        #expect(StartupReviewBaseline.legacyKeys(of: now) == [
            "label:com.a",
            "path:/x/a.plist",
            "item\u{0}com.a\u{0}/x/a.plist\u{0}"
        ])
    }

    @Test("old keys match only within the item's kind, and one old label key matched twice makes both changed")
    func legacyKeysAreScoped() {
        let agent = item()
        let daemon = StartupItem(kind: .systemDaemon, plistPath: "/y/a.plist", label: "com.a")
        let scoped = StartupReviewBaseline(["label:com.a"], byKind: [.userAgent: ["label:com.a"]])
        #expect(scoped.match(agent) == .reviewedBeforeUpgrade)
        #expect(scoped.match(daemon) == .new)
        let twin = item("/x/twin.plist")
        #expect(scoped.matches([agent, twin]) == [.changed, .changed])
        #expect(scoped.matches([agent, daemon]) == [.reviewedBeforeUpgrade, .new])
        let byPath = StartupReviewBaseline(["label:com.a", "path:/x/a.plist"])
        #expect(byPath.matches([agent, twin]) == [.reviewedBeforeUpgrade, .changed]) // its own path key decides
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
