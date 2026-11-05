import Foundation
@testable import MainternanceData
import MainternanceDomain
import Testing

/// A reviewed job that was rewritten to run something else, or replaced by another file with the same label, is
/// flagged "Changed" and counted on Home; a baseline saved before programs were part of the review counts as
/// reviewed once and is upgraded, so later changes are flagged too.
@Suite("Startup changed since review")
struct StartupChangeTests {
    private func savedKeys(_ fixture: StartupFixture) throws -> [String] {
        let data = try Data(contentsOf: fixture.reviewFile)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        return try #require(object["reviewed"] as? [String])
    }

    /// A program inside the temp folder, so no test names a real path.
    private func dropped(_ fixture: StartupFixture) -> String {
        fixture.userFolder.appendingPathComponent(".local/x").path
    }

    @Test("a reviewed plist rewritten to run another program is changed, counted on Home, and cleared by a review")
    func rewrittenProgram() async throws {
        let fixture = try StartupFixture()
        let services = fixture.services()
        let path = try fixture.job("com.google.keystone.agent", in: fixture.userFolder)
        _ = await services.lister.list() // the baseline
        #expect(await services.lister.list().newCount == 0)
        try fixture.plist(
            "com.google.keystone.agent.plist", in: fixture.userFolder,
            ["Label": "com.google.keystone.agent", "ProgramArguments": [dropped(fixture)]]
        )
        let later = await services.lister.list()
        let item = try #require(later.items.first { $0.plistPath == path })
        #expect(item.isChanged)
        #expect(!item.isNew)
        #expect(later.newCount == 1)
        #expect(await services.newItemCounter.list().newCount == 1) // Home counts it
        #expect(await services.reviewer.markReviewed(later))
        #expect(await services.lister.list().newCount == 0)
    }

    @Test("changing only an argument, or adding Program, also counts as changed")
    func argumentsArePartOfTheProgram() async throws {
        let fixture = try StartupFixture()
        let services = fixture.services()
        try fixture.plist(
            "a.plist",
            in: fixture.userFolder,
            ["Label": "com.a", "ProgramArguments": ["/bin/true", "-q"]]
        )
        _ = await services.lister.list()
        try fixture.plist(
            "a.plist",
            in: fixture.userFolder,
            ["Label": "com.a", "ProgramArguments": ["/bin/true", "-x"]]
        )
        #expect(await services.lister.list().items.map(\.isChanged) == [true])
        let review = await services.lister.list()
        #expect(await services.reviewer.markReviewed(review))
        try fixture.plist("a.plist", in: fixture.userFolder, [
            "Label": "com.a", "Program": dropped(fixture), "ProgramArguments": ["/bin/true", "-x"]
        ])
        #expect(await services.lister.list().items.map(\.isChanged) == [true])
    }

    @Test("a reviewed plist deleted and replaced by another file with the same label is changed, not reviewed")
    func replacedFileWithTheSameLabel() async throws {
        let fixture = try StartupFixture()
        let services = fixture.services()
        let original = try fixture.job("com.example.updater", in: fixture.userFolder)
        _ = await services.lister.list()
        try FileManager.default.removeItem(atPath: original)
        try fixture.job("com.example.updater", in: fixture.userFolder, file: "other.plist")
        let later = await services.lister.list()
        #expect(later.items.map(\.isChanged) == [true])
        #expect(later.newCount == 1)
    }

    @Test("an unchanged item stays reviewed; an unrelated new one is new, not changed")
    func unchangedAndNew() async throws {
        let fixture = try StartupFixture()
        let services = fixture.services()
        try fixture.job("com.example.a", in: fixture.userFolder)
        _ = await services.lister.list()
        try fixture.job("com.example.b", in: fixture.userFolder)
        let later = await services.lister.list()
        #expect(later.items.first { $0.label == "com.example.a" }.map { !$0.needsReview } == true)
        let added = try #require(later.items.first { $0.label == "com.example.b" })
        #expect(added.isNew && !added.isChanged)
    }

    @Test("an invalid label is left out of the key: the path and the program remain")
    func invalidLabelByPath() async throws {
        let fixture = try StartupFixture()
        let path = try fixture.job("--version", in: fixture.userFolder, file: "odd.plist")
        let item = LaunchItemReader.item(at: path, kind: .userAgent)
        _ = await fixture.services().lister.list()
        #expect(try savedKeys(fixture) == ["item2\u{0}\u{0}\(path)\u{0}\(#require(item.programFingerprint))"])
    }

    // MARK: Baselines saved before programs were part of the review

    private func writeOldBaseline(_ fixture: StartupFixture, _ keys: [String]) throws {
        try FileManager.default.createDirectory(at: fixture.reviewFolder, withIntermediateDirectories: true)
        let object: [String: Any] = ["reviewed": keys, "byKind": ["userAgent": keys]]
        try JSONSerialization.data(withJSONObject: object).write(to: fixture.reviewFile)
    }

    @Test("an old baseline counts as reviewed once and is upgraded; a later program change is then flagged")
    func oldBaselineIsUpgraded() async throws {
        let fixture = try StartupFixture()
        let services = fixture.services()
        let path = try fixture.job("com.example.a", in: fixture.userFolder)
        try writeOldBaseline(fixture, ["label:com.example.a"])
        let first = await services.lister.list()
        #expect(first.baselineEstablished)
        #expect(first.newCount == 0)
        #expect(first.items.allSatisfy { !$0.needsReview })
        let current = LaunchItemReader.item(at: path, kind: .userAgent).reviewKey
        #expect(try savedKeys(fixture) == [current]) // the old key is gone, so it can never hide a change
        try fixture.plist("com.example.a.plist", in: fixture.userFolder, [
            "Label": "com.example.a", "ProgramArguments": [dropped(fixture)]
        ])
        #expect(await services.lister.list().items.map(\.isChanged) == [true])
    }

    @Test("an old path key (an item that could not be read then) is upgraded the same way")
    func oldPathKeyIsUpgraded() async throws {
        let fixture = try StartupFixture()
        let services = fixture.services()
        let path = try fixture.job("com.example.a", in: fixture.userFolder)
        try writeOldBaseline(fixture, ["path:\(path)"])
        #expect(await services.lister.list().newCount == 0)
        #expect(try savedKeys(fixture) == [LaunchItemReader.item(at: path, kind: .userAgent).reviewKey])
    }

    @Test("Home's counter upgrades an old baseline itself: trusted once, then a later change shows on Home")
    func counterUpgrades() async throws {
        let fixture = try StartupFixture()
        let clock = TestClock()
        let services = fixture.services(clock: clock.reading)
        let path = try fixture.plist("com.example.a.plist", in: fixture.userFolder, [
            "Label": "com.example.a", "ProgramArguments": [dropped(fixture)] // changed before the first look
        ])
        try writeOldBaseline(fixture, ["label:com.example.a"])
        #expect(await services.newItemCounter.list().newCount == 0) // the old review is trusted once
        #expect(try savedKeys(fixture) == [LaunchItemReader.item(at: path, kind: .userAgent).reviewKey])
        try fixture.job("com.example.a", in: fixture.userFolder) // changed after the upgrade
        clock.advance(StartupServices.counterMinimumAge)
        #expect(await services.newItemCounter.list().newCount == 1) // Home shows it without opening Startup
    }

    @Test(
        "an old label key matches only within its own kind: a daemon reusing a reviewed agent's label is not reviewed"
    )
    func oldKeysStayInTheirKind() async throws {
        let fixture = try StartupFixture()
        let services = fixture.services()
        try fixture.job("com.example.a", in: fixture.userFolder)
        try fixture.job("com.example.a", in: fixture.daemonFolder)
        try writeOldBaseline(fixture, ["label:com.example.a"])
        let listed = await services.lister.list()
        let agent = try #require(listed.items.first { $0.kind == .userAgent })
        let daemon = try #require(listed.items.first { $0.kind == .systemDaemon })
        #expect(!agent.needsReview)
        #expect(daemon.needsReview)
        #expect(listed.newCount == 1)
    }

    @Test("an old label key that two files of one kind match cannot tell which was reviewed: both are changed")
    func sharedOldLabelKeyIsChanged() async throws {
        let fixture = try StartupFixture()
        let services = fixture.services()
        try fixture.job("com.example.a", in: fixture.userFolder)
        try fixture.job("com.example.a", in: fixture.userFolder, file: "dropped.plist")
        try writeOldBaseline(fixture, ["label:com.example.a"])
        let listed = await services.lister.list()
        #expect(listed.items.map(\.isChanged) == [true, true])
        #expect(listed.newCount == 2)
    }

    @Test("a reviewed agent that gains DYLD_INSERT_LIBRARIES in EnvironmentVariables is changed and counted")
    func environmentIsPartOfTheProgram() async throws {
        let fixture = try StartupFixture()
        let services = fixture.services()
        try fixture.job("com.example.a", in: fixture.userFolder)
        _ = await services.lister.list()
        try fixture.plist("com.example.a.plist", in: fixture.userFolder, [
            "Label": "com.example.a", "ProgramArguments": ["/bin/true"],
            "EnvironmentVariables": ["DYLD_INSERT_LIBRARIES": dropped(fixture)]
        ])
        let later = await services.lister.list()
        #expect(later.items.map(\.isChanged) == [true])
        #expect(later.newCount == 1)
    }

    @Test("a review saved with the earlier fingerprint (program and arguments only) is trusted once and upgraded")
    func earlierFingerprintIsUpgraded() async throws {
        let fixture = try StartupFixture()
        let services = fixture.services()
        let path = try fixture.job("com.example.a", in: fixture.userFolder)
        let job: [String: Any] = ["Label": "com.example.a", "ProgramArguments": ["/bin/true"]]
        let previous = try #require(LaunchItemReader.programOnlyFingerprint(job))
        let earlier = "item\u{0}com.example.a\u{0}\(path)\u{0}\(previous)"
        try writeOldBaseline(fixture, [earlier])
        let first = await services.lister.list()
        #expect(first.newCount == 0) // no mass "Changed" after the format change
        #expect(try savedKeys(fixture) == [LaunchItemReader.item(at: path, kind: .userAgent).reviewKey])
        try fixture.plist("com.example.a.plist", in: fixture.userFolder, [
            "Label": "com.example.a", "ProgramArguments": ["/bin/true"], "WorkingDirectory": dropped(fixture)
        ])
        #expect(await services.lister.list().items.map(\.isChanged) == [true])
    }

    @Test("the program fingerprint covers Program and every argument, and is nil when the file names neither")
    func fingerprint() {
        let plain = LaunchItemReader.programFingerprint(["ProgramArguments": ["/bin/true"]])
        #expect(plain != nil)
        #expect(plain != LaunchItemReader.programFingerprint(["ProgramArguments": ["/bin/true", "-x"]]))
        #expect(plain != LaunchItemReader.programFingerprint(["Program": "/bin/true"]))
        #expect(plain != LaunchItemReader.programFingerprint(["ProgramArguments": ["/bin/true", ""]]))
        #expect(LaunchItemReader.programFingerprint(["Label": "com.a"]) == nil)
        #expect(plain == LaunchItemReader.programFingerprint(["ProgramArguments": ["/bin/true"], "RunAtLoad": true]))
        let env = LaunchItemReader.programFingerprint([
            "ProgramArguments": ["/bin/true"],
            "EnvironmentVariables": ["A": "1", "B": "2"]
        ])
        #expect(env != plain)
        #expect(env == LaunchItemReader.programFingerprint([
            "EnvironmentVariables": ["B": "2", "A": "1"],
            "ProgramArguments": ["/bin/true"]
        ]))
        #expect(plain != LaunchItemReader.programFingerprint(["ProgramArguments": ["/bin/true"], "BundleProgram": "x"]))
        #expect(plain != LaunchItemReader.programFingerprint([
            "ProgramArguments": ["/bin/true"],
            "WorkingDirectory": "/"
        ]))
        #expect(LaunchItemReader.programFingerprint(["WorkingDirectory": "/"]) != nil)
    }
}
