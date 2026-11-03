import Foundation
@testable import MainternanceData
import MainternanceDomain
import Synchronization
import Testing

/// A damaged or unreadable review file: never all-new, never overwritten in place, Trash only, guard first.
@Suite("Startup review recovery")
struct StartupReviewRecoveryTests {
    private let asideName = "startup-review.json.damaged-1800000000"

    private func writeReview(_ text: String, _ fixture: StartupFixture) throws {
        try FileManager.default.createDirectory(at: fixture.reviewFolder, withIntermediateDirectories: true)
        try Data(text.utf8).write(to: fixture.reviewFile)
    }

    private func reviewText(_ fixture: StartupFixture) throws -> String {
        try String(contentsOf: fixture.reviewFile, encoding: .utf8)
    }

    @Test("a damaged file is moved aside before anything is written, and nothing is shown as new")
    func damagedIsMovedAside() async throws {
        let fixture = try StartupFixture()
        try fixture.job("com.example.a", in: fixture.userFolder)
        try writeReview("{ not json", fixture)
        let services = fixture.services()
        #expect(await services.newItemCounter.list().newCount == nil) // Home's counter leaves it alone
        #expect(try reviewText(fixture) == "{ not json")
        let snapshot = await services.lister.list()
        #expect(snapshot.items.allSatisfy { !$0.isNew })
        #expect(snapshot.newCount == nil)
        #expect(!snapshot.baselineEstablished)
        let aside = fixture.reviewFolder.appendingPathComponent(asideName)
        #expect(try String(contentsOf: aside, encoding: .utf8) == "{ not json")
        #expect(fixture.names(in: fixture.reviewFolder) == ["startup-review.json", asideName])
        #expect(await services.lister.list().newCount == 0) // a fresh baseline from today
    }

    @Test("a file that cannot be read is left alone: nothing written, nothing moved, the count unknown")
    func unreadableIsLeftAlone() async throws {
        let fixture = try StartupFixture()
        try fixture.job("com.example.a", in: fixture.userFolder)
        try writeReview(#"{"reviewed":["label:com.example.old"]}"#, fixture)
        let manager = FileManager.default
        try manager.setAttributes([.posixPermissions: 0o000], ofItemAtPath: fixture.reviewFile.path)
        defer { try? manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fixture.reviewFile.path) }
        let services = fixture.services()
        let snapshot = await services.lister.list()
        #expect(snapshot.reviewUnreadable)
        #expect(snapshot.newCount == nil)
        #expect(snapshot.items.allSatisfy { !$0.isNew })
        #expect(await !services.reviewer.markReviewed(StartupFixture.listing("com.example.a")))
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fixture.reviewFile.path)
        #expect(try reviewText(fixture) == #"{"reviewed":["label:com.example.old"]}"#)
        #expect(fixture.names(in: fixture.reviewFolder) == ["startup-review.json"])
    }

    @Test("a directory in place of the file is unreadable, not damaged")
    func directoryInPlace() async throws {
        let fixture = try StartupFixture()
        try FileManager.default.createDirectory(at: fixture.reviewFile, withIntermediateDirectories: true)
        let services = fixture.services()
        #expect(await services.lister.list().reviewUnreadable)
        #expect(await !services.reviewer.markReviewed(StartupFixture.listing("x")))
        #expect(fixture.names(in: fixture.reviewFolder) == ["startup-review.json"])
    }

    @Test("a FIFO in place of the file is unreadable and never blocks; an oversized file is moved aside as damaged")
    func boundedRead() async throws {
        let fixture = try StartupFixture()
        try fixture.job("com.example.a", in: fixture.userFolder)
        try FileManager.default.createDirectory(at: fixture.reviewFolder, withIntermediateDirectories: true)
        #expect(mkfifo(fixture.reviewFile.path, 0o600) == 0)
        let services = fixture.services()
        let blocked = await within(5, "a FIFO must not block the review store") { await services.lister.list() }
        #expect(blocked?.reviewUnreadable == true)
        #expect(await within(5, "nor Mark all as reviewed") {
            await services.reviewer.markReviewed(StartupFixture.listing("a"))
        } == false)
        let other = try StartupFixture()
        try writeReview(String(repeating: " ", count: StartupReviewStore.maxBytes + 1), other)
        let large = await other.services().lister.list()
        #expect(!large.reviewUnreadable)
        #expect(other.names(in: other.reviewFolder) == ["startup-review.json", asideName])
    }

    @Test("past the bounded number of damaged copies the oldest goes to the (fake) Trash, never deleted")
    func copiesRotateThroughTrash() async throws {
        let fixture = try StartupFixture()
        let services = fixture.services()
        for index in 0 ... StartupReviewStore.maxDamagedCopies {
            try writeReview("damaged \(index)", fixture)
            #expect(await services.reviewer.markReviewed(StartupFixture.listing("a")))
        }
        #expect(fixture.trash.trashed.map(\.lastPathComponent) == [asideName])
        let trashed = fixture.trash.folder.appendingPathComponent(asideName)
        #expect(try String(contentsOf: trashed, encoding: .utf8) == "damaged 0")
        let copies = fixture.names(in: fixture.reviewFolder).filter { $0.hasPrefix("startup-review.json.damaged-") }
        #expect(copies.count == StartupReviewStore.maxDamagedCopies)
        #expect(await services.lister.list().baselineEstablished) // the last write went through
    }

    @Test("a protected oldest copy is never trashed: the damaged file stays and nothing is written")
    func protectedCopyStays() async throws {
        let fixture = try StartupFixture()
        for index in 0 ..< StartupReviewStore.maxDamagedCopies {
            try writeReview("damaged \(index)", fixture)
            #expect(await fixture.services().reviewer.markReviewed(StartupFixture.listing("a")))
        }
        let asked = Mutex<[String]>([])
        let guarded = fixture.services { path in
            asked.withLock { $0.append(path) }
            return true
        }
        try writeReview("one too many", fixture)
        let snapshot = await guarded.lister.list()
        #expect(await !guarded.reviewer.markReviewed(StartupFixture.listing("a")))
        #expect(snapshot.reviewUnreadable)
        #expect(snapshot.newCount == nil)
        #expect(asked.withLock { $0 }.first == fixture.reviewFolder.appendingPathComponent(asideName).path)
        #expect(fixture.trash.trashed.isEmpty)
        #expect(try reviewText(fixture) == "one too many")
    }

    @Test("files that only look like damaged copies are never counted, rotated or trashed")
    func lookalikesIgnored() async throws {
        let fixture = try StartupFixture()
        try FileManager.default.createDirectory(at: fixture.reviewFolder, withIntermediateDirectories: true)
        let strays = ["startup-review.json.damaged-backup", "startup-review.json.damaged-12-1", "preferences.json"]
        for stray in strays {
            try Data("keep".utf8).write(to: fixture.reviewFolder.appendingPathComponent(stray))
        }
        let services = fixture.services()
        for index in 0 ..< StartupReviewStore.maxDamagedCopies {
            try writeReview("damaged \(index)", fixture)
            #expect(await services.reviewer.markReviewed(StartupFixture.listing("a")))
        }
        #expect(fixture.trash.trashed.isEmpty)
        for stray in strays {
            let text = try String(contentsOf: fixture.reviewFolder.appendingPathComponent(stray), encoding: .utf8)
            #expect(text == "keep")
        }
    }
}
