import Foundation
@testable import MainternanceData
import MainternanceDomain
import Testing

/// What the mover refuses among an app's leftovers, with its reason. Only a temp home and a temp Applications folder.
@Suite("Leftover mover refusals")
struct LeftoverMoverRefusalTests {
    @Test("a leftover that is not a direct child of a fixed ~/Library folder is refused", arguments: [
        "Caches/com.example.app/inner", "Documents/report", "Caches", "Caches/../Caches2/x", "Caches/.",
        "Unlisted/com.example.app", "Caches/com.example.app/"
    ])
    func leftoverNotInFolder(relative: String) async throws {
        let fixture = try UninstallerFixture()
        let url = fixture.library.appendingPathComponent(relative, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        var forged = fixture.leftover(relative)
        if relative.hasSuffix("/") {
            forged = Leftover(
                path: url.path + "/", location: "Caches", match: .identifier, bytes: 1, isLowerBound: false,
                type: .directory, identity: forged.identity
            )
        }
        let trash = fixture.trash()
        let outcome = try await fixture.moveLeftovers([forged], trash)
        #expect(outcome.failedLeftovers.map(\.reason) == [UninstallRefusal.notInUninstallerFolder.text])
        #expect(outcome.movedBytes == 0)
        #expect(trash.calls.isEmpty)
        #expect(fixture.exists(url.path))
    }

    @Test("a leftover in the home folder's Documents is refused, even when asked directly")
    func leftoverInDocuments() async throws {
        let fixture = try UninstallerFixture()
        let documents = fixture.home.appendingPathComponent("Documents/thesis", isDirectory: true)
        try FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)
        let forged = Leftover(
            path: documents.path, location: "Caches", match: .identifier, bytes: 1, isLowerBound: false,
            type: .directory, identity: fixture.identity(documents.path)
        )
        let trash = fixture.trash()
        let outcome = try await fixture.moveLeftovers([forged], trash)
        #expect(outcome.failedLeftovers.map(\.reason) == [UninstallRefusal.notInUninstallerFolder.text])
        #expect(trash.calls.isEmpty)
    }

    @Test("a leftover reached through a linked folder is refused")
    func leftoverThroughLink() async throws {
        let fixture = try UninstallerFixture()
        let real = fixture.temp.url.appendingPathComponent("real/victim", isDirectory: true)
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        try fixture.link(
            fixture.library.appendingPathComponent("Caches/hop"),
            to: real.deletingLastPathComponent().path
        )
        let forged = Leftover(
            path: fixture.library.appendingPathComponent("Caches/hop/victim").path, location: "Caches",
            match: .identifier, bytes: 1, isLowerBound: false, type: .directory, identity: fixture.identity(real.path)
        )
        let trash = fixture.trash()
        let outcome = try await fixture.moveLeftovers([forged], trash)
        #expect(outcome.failedLeftovers.map(\.reason) == [UninstallRefusal.notInUninstallerFolder.text])
        #expect(trash.calls.isEmpty)
        #expect(fixture.exists(real.path))
    }

    @Test("leftovers under a ~/Library that is a link are refused")
    func linkedLibrary() async throws {
        let fixture = try UninstallerFixture()
        let real = fixture.temp.url.appendingPathComponent("OtherLibrary", isDirectory: true)
        let victim = real.appendingPathComponent("Caches/com.example.app", isDirectory: true)
        try FileManager.default.createDirectory(at: victim, withIntermediateDirectories: true)
        let app = try await fixture.listedApp()
        try FileManager.default.removeItem(at: fixture.library)
        try fixture.link(fixture.library, to: real.path)
        let forged = fixture.leftover("Caches/com.example.app")
        let trash = fixture.trash()
        let outcome = await fixture.mover(trash).moveToTrash(
            app: app, appBytes: 1, leftovers: [forged], includeApp: false
        )
        #expect(outcome.failedLeftovers.map(\.reason) == [UninstallRefusal.notInUninstallerFolder.text])
        #expect(trash.calls.isEmpty)
        #expect(fixture.exists(victim.path))
    }

    @Test("leftovers that vanished, changed kind, became a link or were replaced are refused with a reason")
    func leftoversChanged() async throws {
        let fixture = try UninstallerFixture()
        for name in ["gone", "kind", "link", "replaced"] {
            try fixture.library("Caches/\(name)/a.bin", bytes: 10)
        }
        let leftovers = ["gone", "kind", "link", "replaced"].map { fixture.leftover("Caches/\($0)") }
        let caches = fixture.library.appendingPathComponent("Caches")
        for name in ["gone", "kind", "link", "replaced"] {
            try FileManager.default.removeItem(at: caches.appendingPathComponent(name))
        }
        try fixture.library("Caches/kind", bytes: 10)
        try fixture.link(caches.appendingPathComponent("link"), to: fixture.home.path)
        try fixture.library("Caches/replaced/b.bin", bytes: 10)
        let trash = fixture.trash()
        let outcome = try await fixture.moveLeftovers(leftovers, trash)
        let reasons = Dictionary(uniqueKeysWithValues: outcome.failedLeftovers.map { ($0.leftover.name, $0.reason) })
        #expect(reasons["gone"] == CleanupRefusal.vanished.text)
        #expect(reasons["kind"] == CleanupRefusal.changed.text)
        #expect(reasons["link"] == CleanupRefusal.changed.text)
        #expect(reasons["replaced"] == CleanupRefusal.changed.text)
        #expect(outcome.movedLeftovers.isEmpty)
        #expect(trash.calls.isEmpty)
        #expect(fixture.exists(fixture.home.path))
    }

    @Test("a leftover on another volume is refused")
    func leftoverOtherVolume() async throws {
        let fixture = try UninstallerFixture()
        try fixture.library("Caches/mounted/a.bin", bytes: 10)
        let trash = fixture.trash()
        let mover = fixture.mover(trash, volume: { path, info in
            path.hasSuffix("/mounted") ? info.device &+ 1 : info.device
        })
        let outcome = try await fixture.moveLeftovers([fixture.leftover("Caches/mounted")], trash, using: mover)
        #expect(outcome.failedLeftovers.map(\.reason) == [UninstallRefusal.otherVolume.text])
        #expect(trash.calls.isEmpty)
    }

    @Test("a leftover link into /System or to the real home folder is refused by the real guard")
    func leftoverLinkToProtected() async throws {
        let fixture = try UninstallerFixture()
        let caches = fixture.library.appendingPathComponent("Caches", isDirectory: true)
        try FileManager.default.createDirectory(at: caches, withIntermediateDirectories: true)
        try fixture.link(caches.appendingPathComponent("sys"), to: "/System")
        try fixture.link(caches.appendingPathComponent("me"), to: NSHomeDirectory())
        let trash = fixture.trash()
        let outcome = try await fixture.moveLeftovers(
            [fixture.leftover("Caches/sys"), fixture.leftover("Caches/me")],
            trash
        )
        let expected = Array(repeating: CleanupRefusal.protectedLink.text, count: 2)
        #expect(outcome.failedLeftovers.map(\.reason) == expected)
        #expect(trash.calls.isEmpty)
    }

    @Test("a protected leftover is refused")
    func leftoverProtected() async throws {
        let fixture = try UninstallerFixture()
        try fixture.library("Caches/keep/a.bin", bytes: 10)
        try fixture.library("Caches/go/a.bin", bytes: 10)
        let trash = fixture.trash()
        let mover = fixture.mover(trash, isProtected: { $0.hasSuffix("/keep") })
        let outcome = try await fixture.moveLeftovers(
            [fixture.leftover("Caches/keep"), fixture.leftover("Caches/go")],
            trash,
            using: mover
        )
        #expect(outcome.failedLeftovers.map(\.reason) == [CleanupRefusal.protected.text])
        #expect(outcome.movedLeftovers.map(\.name) == ["go"])
        #expect(outcome.movedBytes == 7)
        #expect(trash.moves.map(\.source.lastPathComponent) == ["go"])
    }

    @Test("a leftover link to an ordinary place moves as the link itself; what it points to stays")
    func leftoverLinkMovesAsLink() async throws {
        let fixture = try UninstallerFixture()
        let elsewhere = fixture.temp.url.appendingPathComponent("elsewhere", isDirectory: true)
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        let kept = elsewhere.appendingPathComponent("keep.bin")
        try Data("keep".utf8).write(to: kept)
        try fixture.link(fixture.library.appendingPathComponent("Caches/com.example.app"), to: elsewhere.path)
        let trash = fixture.trash()
        let outcome = try await fixture.moveLeftovers([fixture.leftover("Caches/com.example.app")], trash)
        #expect(outcome.movedLeftovers.count == 1)
        #expect(fixture.exists(kept.path))
        let moved = try #require(trash.moves.first?.destination)
        let type = try FileManager.default.attributesOfItem(atPath: moved.path)[.type] as? FileAttributeType
        #expect(type == .typeSymbolicLink)
    }

    @Test("a leftover with no recorded identity cannot be checked, so it is left alone")
    func leftoverWithoutIdentity() async throws {
        let fixture = try UninstallerFixture()
        let url = try fixture.library("Caches/com.example.app")
        let bare = Leftover(
            path: url.path, location: "Caches", match: .identifier, bytes: 1, isLowerBound: false, type: .directory
        )
        let trash = fixture.trash()
        let outcome = try await fixture.moveLeftovers([bare], trash)
        #expect(outcome.failedLeftovers.map(\.reason) == [CleanupRefusal.unreadable.text])
        #expect(trash.calls.isEmpty)
    }
}
