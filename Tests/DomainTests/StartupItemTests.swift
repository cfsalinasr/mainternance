import Foundation
import MainternanceDomain
import Testing

@Suite("Startup items")
struct StartupItemTests {
    @Test("a label that could be read as an option, a path or several lines never counts as valid", arguments: [
        "", "--version", "-h", "../x", "a/b", "/abs", "line\nbreak", "tab\there", "nul\u{0}", "bell\u{7}",
        "zero\u{200B}width\u{202E}", "sep\u{2028}line", ".", "..", String(repeating: "a", count: 256),
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

    @Test("the review key is the label, or the file path when there is no label; the two never collide")
    func reviewKeys() {
        let labeled = StartupItem(kind: .userAgent, plistPath: "/x/a.plist", label: "/x/a.plist")
        let unlabeled = StartupItem(kind: .userAgent, plistPath: "/x/a.plist")
        #expect(labeled.reviewKey == "label:/x/a.plist")
        #expect(unlabeled.reviewKey == "path:/x/a.plist")
        #expect(labeled.reviewKey != unlabeled.reviewKey)
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
        #expect(StartupError.notAllowed.errorDescription?.contains("administrator") == true)
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
    }
}
