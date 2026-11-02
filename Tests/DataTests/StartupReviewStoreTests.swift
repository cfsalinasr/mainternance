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
        await services.reviewer.markReviewed(later.items.map(\.reviewKey))
        let reviewed = await services.lister.list()
        #expect(reviewed.newCount == 0)
        #expect(reviewed.items.allSatisfy { !$0.isNew })
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
