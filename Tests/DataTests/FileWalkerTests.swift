import Foundation
@testable import MainternanceData
import MainternanceDomain
import Testing

/// Walking a temp home: plain files only, no links followed, no other volumes, no Library, Trash or dot-folders.
@Suite("File walker")
struct FileWalkerTests {
    @Test("every plain file below the home folder is reported once, with its size and identity")
    func walksNestedFiles() throws {
        let fixture = try FilesFixture()
        try fixture.file("Documents/a.txt", bytes: 5000)
        try fixture.file("Documents/deep/er/b.bin", bytes: 70000)
        try fixture.file("top.mov", bytes: 300)
        try fixture.file(".zshrc", bytes: 10)
        try fixture.folder("Empty")
        let record = fixture.walk()
        #expect(Set(record.paths) == [
            fixture.path("Documents/a.txt"), fixture.path("Documents/deep/er/b.bin"), fixture.path("top.mov"),
            fixture.path(".zshrc")
        ])
        #expect(record.unreadable == 0)
        let big = try #require(record.files.first { $0.path.hasSuffix("b.bin") })
        #expect(isAbout(big.bytes, 70000))
        #expect(big.stat.isRegular)
        #expect(!big.isPackageRoot)
    }

    @Test("Library at the top of home, the Trash and any dot-folder are never entered")
    func exclusions() throws {
        let fixture = try FilesFixture()
        try fixture.file("Library/Caches/big.bin", bytes: 5000)
        try fixture.file(".Trash/old.bin", bytes: 5000)
        try fixture.file(".git/objects/pack.bin", bytes: 5000)
        try fixture.file("Projects/.build/out.o", bytes: 5000)
        try fixture.file("Projects/Library/kept.txt", bytes: 10)
        try fixture.file("Projects/main.swift", bytes: 10)
        let record = fixture.walk()
        #expect(Set(record.paths) == [fixture.path("Projects/Library/kept.txt"), fixture.path("Projects/main.swift")])
    }

    @Test("links are never followed or counted: to /System, to home, to a folder above itself")
    func linksNotFollowed() throws {
        let fixture = try FilesFixture()
        try fixture.file("Documents/a.txt", bytes: 100)
        try fixture.link("Documents/system", to: "/System")
        try fixture.link("Documents/home", to: fixture.home.path)
        try fixture.link("Documents/loop", to: "..")
        try fixture.link("file-link", to: fixture.path("Documents/a.txt"))
        let record = fixture.walk()
        #expect(record.paths == [fixture.path("Documents/a.txt")])
    }

    @Test("a folder on another volume (a mount point) is not entered")
    func otherVolume() throws {
        let fixture = try FilesFixture()
        try fixture.file("Mounted/inside.bin", bytes: 100)
        try fixture.file("Local/kept.bin", bytes: 100)
        let mount = fixture.path("Mounted")
        let walker = fixture.walker(volume: { path, info in path == mount ? info.device &+ 1 : info.device })
        #expect(fixture.walk(walker).paths == [fixture.path("Local/kept.bin")])
    }

    @Test("a protected folder is neither entered nor reported")
    func protectedSkipped() throws {
        let fixture = try FilesFixture()
        try fixture.file("Applications/Mainternance.app/Contents/MacOS/Mainternance", bytes: 100)
        try fixture.file("Locked/deeper/inner.bin", bytes: 100)
        try fixture.file("open.bin", bytes: 100)
        let locked = fixture.path("Locked")
        let app = fixture.path("Applications/Mainternance.app")
        let walker = fixture.walker(isProtected: { $0 == locked || $0 == app })
        #expect(fixture.walk(walker).paths == [fixture.path("open.bin")])
    }

    @Test("only folders are checked against the protected places, never each plain file")
    func protectedAskedForFoldersOnly() throws {
        let fixture = try FilesFixture()
        try fixture.file("A/one.bin", bytes: 10)
        try fixture.file("A/B/two.bin", bytes: 10)
        try fixture.file("three.bin", bytes: 10)
        let asked = Received<String>()
        let walker = fixture.walker(isProtected: { asked.add($0); return false })
        #expect(fixture.walk(walker).files.count == 3)
        #expect(Set(asked.values) == [fixture.path("A"), fixture.path("A/B")])
    }

    @Test("a home folder that is a link is resolved once and walked; paths are reported resolved")
    func linkedHome() throws {
        let fixture = try FilesFixture()
        try fixture.file("Documents/a.txt", bytes: 100)
        let linked = fixture.temp.url.appendingPathComponent("linked-home")
        try FileManager.default.createSymbolicLink(atPath: linked.path, withDestinationPath: fixture.home.path)
        let walker = fixture.walker(home: linked)
        #expect(walker.root == fixture.home.path)
        #expect(fixture.walk(walker).paths == [fixture.path("Documents/a.txt")])
    }

    @Test("a folder that cannot be read is counted and the walk goes on")
    func unreadableFolder() async throws {
        let fixture = try FilesFixture()
        let secret = try fixture.folder("Secret")
        try fixture.file("Secret/hidden.bin", bytes: 100)
        try fixture.file("Open/seen.bin", bytes: 100)
        let record = await fixture.unreadable(secret) { fixture.walk() }
        #expect(record.unreadable == 1)
        #expect(record.paths == [fixture.path("Open/seen.bin")])
    }

    @Test("a hard-linked pair is one file")
    func hardLinksOnce() throws {
        let fixture = try FilesFixture()
        let original = try fixture.file("A/original.bin", bytes: 50000)
        try FileManager.default.createDirectory(
            at: fixture.home.appendingPathComponent("B"),
            withIntermediateDirectories: true
        )
        try FileManager.default.linkItem(at: original, to: fixture.home.appendingPathComponent("B/twin.bin"))
        let record = fixture.walk()
        #expect(record.files.count == 1)
    }

    @Test("a package counts once, as a whole, and its contents are not reported")
    func packagesOnce() throws {
        let fixture = try FilesFixture()
        try fixture.file("Applications/Tool.app/Contents/MacOS/Tool", bytes: 40000)
        try fixture.file("Applications/Tool.app/Contents/Resources/big.bin", bytes: 60000)
        try fixture.file("Pictures/Photos Library.photoslibrary/originals/a.heic", bytes: 30000)
        let record = fixture.walk()
        #expect(Set(record.paths) == [
            fixture.path("Applications/Tool.app"), fixture.path("Pictures/Photos Library.photoslibrary")
        ])
        let allPackages = record.files.allSatisfy(\.isPackageRoot)
        #expect(allPackages)
        let app = try #require(record.files.first { $0.path.hasSuffix("Tool.app") })
        #expect(isAbout(app.bytes, 100_000))
    }

    @Test("odd names are walked and reported exactly as on disk")
    func oddNames() throws {
        let fixture = try FilesFixture()
        let names = ["with space.txt", "-leading dash", "new\nline.txt", "evil\u{202E}gpj.exe"]
        for name in names {
            try fixture.file("Odd/\(name)", bytes: 10)
        }
        #expect(Set(fixture.walk().paths) == Set(names.map { fixture.path("Odd/\($0)") }))
    }

    @Test("a deeply nested tree is walked without recursion")
    func deepTree() throws {
        let fixture = try FilesFixture()
        let deep = Array(repeating: "d", count: 200).joined(separator: "/")
        try fixture.file("\(deep)/bottom.bin", bytes: 10)
        #expect(fixture.walk().paths == [fixture.path("\(deep)/bottom.bin")])
    }

    @Test("asking it to stop ends the walk promptly")
    func stopsPromptly() throws {
        let fixture = try FilesFixture()
        for index in 0 ..< 300 {
            try fixture.file("Many/f\(index).bin", bytes: 10)
        }
        let record = fixture.walk(stopAfter: 5)
        #expect(record.files.count == 5)
    }
}
