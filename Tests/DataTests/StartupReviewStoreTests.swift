import Foundation
@testable import MainternanceData
import MainternanceDomain
import Testing

/// The review baseline: what counts as new, when the baseline is written, and Home's read-only counter.
@Suite("Startup review baseline")
struct StartupReviewStoreTests {
    private func savedKeys(_ fixture: StartupFixture) throws -> [String] {
        let data = try Data(contentsOf: fixture.reviewFile)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        return try #require(object["reviewed"] as? [String])
    }

    @Test("the first listing establishes the baseline silently: nothing is new and the count is unknown")
    func firstListing() async throws {
        let fixture = try StartupFixture()
        try fixture.job("com.example.a", in: fixture.userFolder)
        let unlabeled = try fixture.plist("NoLabel.plist", in: fixture.daemonFolder, ["Program": "/bin/true"])
        let snapshot = await fixture.services().lister.list()
        #expect(!snapshot.baselineEstablished)
        #expect(snapshot.newCount == nil)
        #expect(snapshot.items.allSatisfy { !$0.isNew })
        #expect(try savedKeys(fixture) == ["label:com.example.a", "path:\(unlabeled)"])
        #expect(permissions(fixture.reviewFile) == 0o600)
    }

    @Test("after the baseline, a new plist is new and counted; marking all as reviewed clears it")
    func newItems() async throws {
        let fixture = try StartupFixture()
        let services = fixture.services()
        try fixture.job("com.example.a", in: fixture.userFolder)
        _ = await services.lister.list()
        let settled = await services.lister.list()
        #expect(settled.baselineEstablished)
        #expect(settled.newCount == 0)
        try fixture.job("com.example.b", in: fixture.agentFolder)
        let later = await services.lister.list()
        #expect(later.newCount == 1)
        #expect(later.items.filter(\.isNew).map(\.label) == ["com.example.b"])
        #expect(await services.reviewer.markReviewed(later))
        let reviewed = await services.lister.list()
        #expect(reviewed.newCount == 0)
        #expect(reviewed.items.allSatisfy { !$0.isNew })
    }

    @Test("Home's counter is read again only after a minute, or once the screen listed or marked as reviewed")
    func counterIsCached() async throws {
        let fixture = try StartupFixture()
        let clock = TestClock()
        let services = fixture.services(clock: clock.reading)
        try fixture.job("com.example.a", in: fixture.userFolder)
        _ = await services.lister.list() // the baseline
        #expect(await services.newItemCounter.list().newCount == 0)
        try fixture.job("com.example.b", in: fixture.userFolder)
        clock.advance(59)
        #expect(await services.newItemCounter.list().newCount == 0) // cached: no file read
        clock.advance(1)
        #expect(await services.newItemCounter.list().newCount == 1) // a minute old: read again
        let listed = await services.lister.list() // the Startup screen refreshed
        try fixture.job("com.example.c", in: fixture.userFolder)
        #expect(await services.newItemCounter.list().newCount == 2)
        #expect(await services.reviewer.markReviewed(listed))
        #expect(await services.newItemCounter.list().newCount == 1) // only c, added after that listing
    }

    @Test("Home's counter never writes the baseline and never runs launchctl")
    func counterIsReadOnly() async throws {
        let fixture = try StartupFixture()
        let services = fixture.services()
        try fixture.job("com.example.a", in: fixture.userFolder)
        let before = await services.newItemCounter.list()
        #expect(before.newCount == nil)
        #expect(!FileManager.default.fileExists(atPath: fixture.reviewFile.path))
        _ = await services.lister.list() // the Startup screen establishes it
        try fixture.job("com.example.b", in: fixture.userFolder)
        let after = await services.newItemCounter.list()
        #expect(after.newCount == 1)
        #expect(after.items.allSatisfy { $0.isEnabled == nil })
        #expect(fixture.launchctl.calls.count == 2) // only the screen's listing asked launchd
    }

    @Test("launchd's answers fill the state: agents from the user's domain, daemons from the system domain")
    func statesApplied() async throws {
        let fixture = try StartupFixture()
        try fixture.job("com.user.off", in: fixture.userFolder)
        try fixture.job("com.user.default", in: fixture.userFolder)
        try fixture.job("com.allusers.off", in: fixture.agentFolder)
        try fixture.job("com.daemon.off", in: fixture.daemonFolder)
        fixture.launchctl.configure {
            $0.user = FakeLaunchctl.disabledOutput([("com.user.off", false), ("com.allusers.off", false)])
            $0.system = FakeLaunchctl.disabledOutput([("com.daemon.off", false)])
        }
        let items = await fixture.services().lister.list().items
        let states = Dictionary(uniqueKeysWithValues: items.map { ($0.label ?? "", $0.isEnabled) })
        #expect(states == [
            "com.user.off": false, "com.user.default": true, "com.allusers.off": false, "com.daemon.off": false
        ])
    }

    @Test("with no launchd entry for a label, the plist's own Disabled key decides: true is Off, else On")
    func plistDisabledKey() async throws {
        let fixture = try StartupFixture()
        let program = ["/bin/true"]
        try fixture.plist("a.plist", in: fixture.userFolder, ["Label": "com.file.off", "Disabled": true,
                                                              "ProgramArguments": program])
        try fixture.plist("b.plist", in: fixture.userFolder, ["Label": "com.file.on", "Disabled": false,
                                                              "ProgramArguments": program])
        try fixture.plist("c.plist", in: fixture.userFolder, ["Label": "com.override.on", "Disabled": true,
                                                              "ProgramArguments": program])
        try fixture.plist("d.plist", in: fixture.daemonFolder, ["Label": "com.daemon.off", "Disabled": true,
                                                                "ProgramArguments": program])
        try fixture.job("com.file.silent", in: fixture.userFolder)
        fixture.launchctl.configure {
            $0.user = FakeLaunchctl.disabledOutput([("com.override.on", true)])
            $0.system = FakeLaunchctl.disabledOutput([])
        }
        let items = await fixture.services().lister.list().items
        let states = Dictionary(uniqueKeysWithValues: items.map { ($0.label ?? "", $0.isEnabled) })
        #expect(states == [
            "com.file.off": false, "com.file.on": true, "com.override.on": true, "com.daemon.off": false,
            "com.file.silent": true
        ])
    }

    @Test("an item keyed by its path while unreadable is not new once it reads with its label")
    func unreadableThenLabeled() async throws {
        let fixture = try StartupFixture()
        let services = fixture.services()
        let path = try fixture.raw("com.example.a.plist", in: fixture.userFolder, Data("garbage".utf8))
        _ = await services.lister.list() // baseline: the path, since there was no label to read
        #expect(try savedKeys(fixture) == ["path:\(path)"])
        try fixture.job("com.example.a", in: fixture.userFolder)
        let later = await services.lister.list()
        #expect(later.newCount == 0)
        #expect(later.items.allSatisfy { !$0.isNew })
    }

    @Test("an invalid label is remembered by path")
    func invalidLabelByPath() async throws {
        let fixture = try StartupFixture()
        let path = try fixture.job("--version", in: fixture.userFolder, file: "odd.plist")
        _ = await fixture.services().lister.list()
        #expect(try savedKeys(fixture) == ["path:\(path)"])
    }

    @Test("marking as reviewed while a launchd folder cannot be opened keeps what was known for that folder")
    func unreadableFolderKeepsKnownKeys() async throws {
        let fixture = try StartupFixture()
        let services = fixture.services()
        try fixture.job("com.allusers.a", in: fixture.agentFolder)
        try fixture.job("com.user.a", in: fixture.userFolder)
        try fixture.job("com.user.gone", in: fixture.userFolder, file: "gone.plist")
        _ = await services.lister.list()
        let manager = FileManager.default
        try manager.setAttributes([.posixPermissions: 0o000], ofItemAtPath: fixture.agentFolder.path)
        defer { try? manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fixture.agentFolder.path) }
        let blind = await services.lister.list()
        #expect(blind.unreadableFolders == [fixture.agentFolder.path])
        var moved = blind
        moved.items.removeAll { $0.label == "com.user.gone" } // not part of what was reviewed
        #expect(await services.reviewer.markReviewed(moved))
        #expect(try savedKeys(fixture) == ["label:com.allusers.a", "label:com.user.a"])
        try manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fixture.agentFolder.path)
        let seen = await services.lister.list()
        #expect(seen.items.first { $0.label == "com.allusers.a" }?.isNew == false)
        #expect(seen.items.first { $0.label == "com.user.gone" }?.isNew == true) // readable folders are exact
    }

    @Test("a review folder that cannot be written: the first baseline says so and Mark all as reviewed fails")
    func readOnlyReviewFolder() async throws {
        let fixture = try StartupFixture()
        try fixture.job("com.example.a", in: fixture.userFolder)
        let manager = FileManager.default
        try manager.createDirectory(at: fixture.reviewFolder, withIntermediateDirectories: true)
        try manager.setAttributes([.posixPermissions: 0o500], ofItemAtPath: fixture.reviewFolder.path)
        defer { try? manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fixture.reviewFolder.path) }
        let services = fixture.services()
        let first = await services.lister.list()
        #expect(first.reviewReadOnly)
        #expect(first.newCount == nil)
        #expect(!first.baselineEstablished)
        #expect(await !services.reviewer.markReviewed(first))
        #expect(fixture.names(in: fixture.reviewFolder).isEmpty)
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fixture.reviewFolder.path)
        let writable = await services.lister.list()
        #expect(!writable.reviewReadOnly)
        #expect(await services.reviewer.markReviewed(writable))
    }

    @Test("an existing review in a folder that became read-only is still read, but flagged as not savable")
    func readOnlyExistingReview() async throws {
        let fixture = try StartupFixture()
        try fixture.job("com.example.a", in: fixture.userFolder)
        let services = fixture.services()
        _ = await services.lister.list()
        let manager = FileManager.default
        try manager.setAttributes([.posixPermissions: 0o500], ofItemAtPath: fixture.reviewFolder.path)
        defer { try? manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fixture.reviewFolder.path) }
        let later = await services.lister.list()
        #expect(later.baselineEstablished)
        #expect(later.newCount == 0)
        #expect(later.reviewReadOnly)
    }

    @Test("a read-only review marks nothing as new, but the count stays a known zero (not unknown)")
    func readOnlyReviewMarksNothing() async throws {
        let fixture = try StartupFixture()
        try fixture.job("com.example.a", in: fixture.userFolder)
        let services = fixture.services()
        _ = await services.lister.list()
        try fixture.job("com.example.added", in: fixture.userFolder)
        let manager = FileManager.default
        try manager.setAttributes([.posixPermissions: 0o500], ofItemAtPath: fixture.reviewFolder.path)
        defer { try? manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fixture.reviewFolder.path) }
        let later = await services.lister.list()
        #expect(later.baselineEstablished)
        #expect(later.reviewReadOnly)
        #expect(!later.reviewUnreadable)
        #expect(later.newCount == 0)
        #expect(later.items.count == 2)
        #expect(later.items.allSatisfy { !$0.isNew })
        let counted = await services.newItemCounter.list()
        #expect(counted.newCount == 0)
        #expect(counted.items.allSatisfy { !$0.isNew })
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fixture.reviewFolder.path)
        let writable = await services.lister.list()
        #expect(writable.newCount == 1) // once savable again, the added item is new as before
        #expect(writable.items.first { $0.label == "com.example.added" }?.isNew == true)
    }

    @Test("when launchctl fails, the state is unknown for that domain only")
    func failedStatesAreUnknown() async throws {
        let fixture = try StartupFixture()
        try fixture.job("com.user.a", in: fixture.userFolder)
        try fixture.job("com.daemon.a", in: fixture.daemonFolder)
        fixture.launchctl.configure {
            $0.userStatus = 1
            $0.system = FakeLaunchctl.disabledOutput([])
        }
        let items = await fixture.services().lister.list().items
        #expect(items.first { $0.kind == .userAgent }?.isEnabled == nil)
        #expect(items.first { $0.kind == .systemDaemon }?.isEnabled == true)
    }

    @Test("the same label in two folders is listed once per file and noted as a duplicate")
    func duplicates() async throws {
        let fixture = try StartupFixture()
        try fixture.job("com.example.twice", in: fixture.userFolder)
        try fixture.job("com.example.twice", in: fixture.agentFolder)
        try fixture.job("com.example.once", in: fixture.agentFolder)
        let snapshot = await fixture.services().lister.list()
        #expect(snapshot.items.count(where: { $0.label == "com.example.twice" }) == 2)
        #expect(snapshot.duplicateLabels == ["com.example.twice"])
    }

    @Test("an unreadable launchd folder is reported in the snapshot")
    func unreadableFolder() async throws {
        let fixture = try StartupFixture()
        let manager = FileManager.default
        try manager.setAttributes([.posixPermissions: 0o000], ofItemAtPath: fixture.agentFolder.path)
        defer { try? manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fixture.agentFolder.path) }
        let snapshot = await fixture.services().lister.list()
        #expect(snapshot.unreadableFolders == [fixture.agentFolder.path])
    }
}
