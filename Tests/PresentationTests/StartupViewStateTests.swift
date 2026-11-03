import Foundation
import MainternanceDomain
@testable import MainternancePresentation
import Testing

@MainActor
@Suite("Startup screen state")
struct StartupViewStateTests {
    private let updater = "/Users/me/Library/LaunchAgents/com.example.updater.plist"

    @Test("refresh fills the snapshot and groups the rows by kind")
    func refreshFills() async {
        let rig = StartupRig()
        #expect(rig.state.snapshot == nil)
        #expect(rig.state.items(of: .userAgent).isEmpty)
        await rig.state.refresh()
        #expect(rig.state.snapshot == StartupRig.sample)
        #expect(!rig.state.isLoading)
        #expect(!rig.state.showsLoading)
        #expect(rig.state.items(of: .userAgent).map(\.label) == ["com.example.updater", "com.example.sync"])
        #expect(rig.state.items(of: .systemAgent).count == 1)
        #expect(rig.state.items(of: .systemDaemon).count == 1)
        #expect(!rig.state.showsEmptyState)
    }

    @Test("switching a user agent asks launchd, reads the state again and says when it takes effect")
    func toggleUserAgent() async {
        let rig = StartupRig()
        await rig.state.refresh()
        await rig.state.setEnabled(updater, false)
        #expect(rig.fake.toggles.map(\.id) == [updater])
        #expect(rig.fake.toggles.map(\.enabled) == [false])
        #expect(rig.fake.lists == 2) // re-read after the change
        #expect(rig.state.snapshot?.items.first { $0.id == updater }?.isEnabled == false)
        #expect(rig.state.message == StartupText.takesEffect)
        #expect(rig.state.message == "Takes effect at your next login.")
        #expect(rig.state.busyIDs.isEmpty)
    }

    @Test("a refused switch leaves the shown state as it was and says why")
    func toggleFailure() async {
        let rig = StartupRig()
        rig.fake.configure { $0.controlError = .failed("Operation not permitted") }
        await rig.state.refresh()
        await rig.state.setEnabled(updater, false)
        #expect(rig.state.snapshot?.items.first { $0.id == updater }?.isEnabled == true)
        #expect(rig.state.message == "macOS could not change it: Operation not permitted")
        #expect(rig.fake.lists == 1)
        #expect(rig.state.busyIDs.isEmpty)
    }

    @Test("an item for all users or a daemon cannot be switched: nothing is asked, the reason is shown")
    func systemItemsAreReadOnly() async throws {
        let rig = StartupRig()
        await rig.state.refresh()
        for item in rig.state.items(of: .systemAgent) + rig.state.items(of: .systemDaemon) {
            #expect(!item.canToggle)
            #expect(rig.state.readOnlyNote(item) == StartupText.allUsersNote)
            await rig.state.setEnabled(item.id, false)
        }
        #expect(rig.fake.toggles.isEmpty)
        #expect(rig.state.message == StartupError.notAllowed.errorDescription)
        let own = try #require(rig.state.items(of: .userAgent).first)
        #expect(rig.state.readOnlyNote(own) == nil)
    }

    @Test("an id that is not listed changes nothing")
    func unknownID() async {
        let rig = StartupRig()
        await rig.state.refresh()
        await rig.state.setEnabled("/nowhere.plist", true)
        rig.state.reveal("/nowhere.plist")
        #expect(rig.fake.toggles.isEmpty)
        #expect(rig.revealed.all.isEmpty)
        #expect(rig.state.message == nil)
    }

    @Test("mark all as reviewed hands every item's key to the reviewer and refreshes; the New badges go")
    func markAllReviewed() async {
        let rig = StartupRig()
        await rig.state.refresh()
        #expect(rig.state.snapshot?.items.contains(where: \.isNew) == true)
        await rig.state.markAllReviewed()
        #expect(rig.fake.reviewed == [StartupRig.sample.items.map(\.reviewKey)])
        #expect(rig.fake.lists == 2)
        #expect(rig.state.snapshot?.items.contains(where: \.isNew) == false)
        #expect(rig.state.snapshot?.newCount == 0)
    }

    @Test("only the listing that created the baseline says so; the next reading (which can show New) does not")
    func baselineNote() async {
        var first = StartupRig.sample
        first.baselineEstablished = false
        first.newCount = nil
        let rig = StartupRig(first)
        #expect(rig.state.baselineNote == nil) // nothing claimed before the first reading
        await rig.state.refresh()
        #expect(rig.state.baselineNote == "Showing a baseline from today: nothing counts as new yet.")
        rig.fake.configure { $0.snapshot = StartupRig.sample } // a later reading, with one item new
        await rig.state.refresh()
        #expect(rig.state.baselineNote == nil)
        #expect(rig.state.snapshot?.items.contains(where: \.isNew) == true)
    }

    @Test("an unreadable review says nothing is marked as new; an established one says nothing")
    func reviewNotes() async {
        var unreadable = StartupRig.sample
        unreadable.baselineEstablished = false
        unreadable.newCount = nil
        unreadable.reviewUnreadable = true
        let blocked = StartupRig(unreadable)
        await blocked.state.refresh()
        #expect(blocked.state.baselineNote == StartupText.reviewUnreadable)
        let settled = StartupRig()
        await settled.state.refresh()
        #expect(settled.state.baselineNote == nil)
    }

    @Test("empty folders show the empty state, but only once something was read")
    func emptyState() async {
        let rig = StartupRig(StartupSnapshot(baselineEstablished: true, newCount: 0))
        #expect(!rig.state.showsEmptyState)
        #expect(!rig.state.canMarkReviewed)
        await rig.state.markAllReviewed() // nothing read, nothing to mark
        #expect(rig.fake.reviewed.isEmpty)
        await rig.state.refresh()
        #expect(rig.state.showsEmptyState)
        #expect(rig.state.canMarkReviewed)
    }

    @Test("launchd's state reads On, Off or Unknown, never a guess")
    func stateText() {
        #expect(StartupText.state(true) == "On")
        #expect(StartupText.state(false) == "Off")
        #expect(StartupText.state(nil) == "Unknown")
    }

    @Test("a switch is shown only for the owner's agents whose state is known")
    func switches() {
        let rig = StartupRig()
        #expect(rig.state.showsSwitch(StartupRig.item("com.a")))
        #expect(!rig.state.showsSwitch(StartupRig.item("com.a", enabled: nil)))
        #expect(!rig.state.showsSwitch(StartupRig.item("com.a", kind: .systemAgent)))
        #expect(!rig.state.showsSwitch(StartupRig.item("--version")))
    }

    @Test("Reveal in Finder gets the plist path, only for items in the snapshot")
    func reveal() async {
        let rig = StartupRig()
        rig.state.reveal(updater)
        #expect(rig.revealed.all.isEmpty) // nothing listed yet
        await rig.state.refresh()
        rig.state.reveal(updater)
        #expect(rig.revealed.all == [updater])
    }

    @Test("rows describe what is registered, by which file, in plain words")
    func rowText() async throws {
        let snapshot = StartupSnapshot(
            items: [
                StartupRig.item("com.twice.job"), StartupRig.item("com.twice.job", kind: .systemAgent),
                StartupRig.item(nil, file: "Mystery"), StartupRig.item(nil, problem: "Could not be read: bad.")
            ],
            baselineEstablished: true, newCount: 0, duplicateLabels: ["com.twice.job"],
            unreadableFolders: ["/Library/LaunchDaemons"]
        )
        let rig = StartupRig(snapshot)
        await rig.state.refresh()
        let twice = try #require(rig.state.items(of: .userAgent).first { $0.label == "com.twice.job" })
        #expect(rig.state.detail(twice) == "com.twice.job · /Applications/com.twice.job.app/Contents/MacOS/helper")
        #expect(rig.state.duplicateNote(twice) == StartupText.duplicate)
        let mystery = try #require(rig.state.items(of: .userAgent).first { $0.name == "Mystery" })
        #expect(rig.state.detail(mystery) == "No label · No program listed")
        #expect(rig.state.duplicateNote(mystery) == nil)
        #expect(rig.state.folderNotes == ["Could not open /Library/LaunchDaemons, so its items are not listed."])
        #expect(rig.state.rowNotes(twice) == [StartupText.duplicate])
        let other = try #require(rig.state.items(of: .systemAgent).first)
        #expect(rig.state.rowNotes(other) == [StartupText.duplicate, StartupText.allUsersNote])
        let broken = try #require(rig.state.items(of: .userAgent).first { $0.readProblem != nil })
        #expect(rig.state.rowNotes(broken) == ["Could not be read: bad."])
        #expect(rig.state.notes == rig.state.folderNotes)
        await rig.state.setEnabled(broken.id, true) // a file that could not be read is never switched
        #expect(rig.state.message == StartupError.unreadable.errorDescription)
        #expect(rig.state.notes == [StartupError.unreadable.errorDescription ?? ""] + rig.state.folderNotes)
    }

    @Test("label and program are shown without bidi, zero-width or control characters")
    func sanitizedDetail() {
        let item = StartupItem(
            kind: .userAgent, plistPath: "/x/a.plist", label: "com.\u{202E}evil\u{200B}", program: "/bin/a\u{0007}b"
        )
        #expect(StartupRig().state.detail(item) == "com.evil · /bin/ab")
    }

    @Test("section titles and the footer are plain")
    func copy() {
        #expect(StartupKind.allCases.map(StartupText.sectionTitle) == [
            "Your agents", "Agents for all users", "System daemons"
        ])
        #expect(StartupText.loginItemsFooter == [
            "Login items you added in System Settings > General > Login Items are managed by macOS",
            "and are not listed here."
        ].joined(separator: " "))
        #expect(StartupText.allUsersNote == "Installed for all users: Mainternance only switches your own agents.")
        #expect(StartupText.markAllReviewed == "Mark all as reviewed")
    }
}
