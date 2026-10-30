import Foundation
@testable import MainternanceData
import Testing

@Suite("Definitions store and paths")
struct DefinitionsStoreTests {
    private func touch(_ name: String, in paths: ClamAVPaths, at date: Date) throws {
        try FileManager.default.createDirectory(at: paths.databaseDirectory, withIntermediateDirectories: true)
        let url = paths.databaseDirectory.appendingPathComponent(name)
        try Data("x".utf8).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
    }

    @Test("paths are pure URL math below the support directory")
    func pathLayout() {
        let base = URL(fileURLWithPath: "/tmp/base dir/Mainternance", isDirectory: true)
        let paths = ClamAVPaths(supportDirectory: base)
        #expect(paths.root.path == "/tmp/base dir/Mainternance/ClamAV")
        #expect(paths.databaseDirectory.path == "/tmp/base dir/Mainternance/ClamAV/database")
        #expect(paths.freshclamConfig.path == "/tmp/base dir/Mainternance/ClamAV/freshclam.conf")
        #expect(paths.quarantineDirectory.path == "/tmp/base dir/Mainternance/Quarantine")
        let quarantineParent = paths.quarantineDirectory.deletingLastPathComponent().path
        #expect(quarantineParent == paths.root.deletingLastPathComponent().path)
    }

    @Test("the default support directory ends in Application Support/Mainternance")
    func defaultPaths() {
        #expect(ClamAVPaths().supportDirectory.path.hasSuffix("/Application Support/Mainternance"))
    }

    @Test("nil when the database directory does not exist or has no definitions")
    func noneIsNil() throws {
        let temp = try TempDirectory()
        let paths = ClamAVPaths(supportDirectory: temp.url)
        #expect(DefinitionsStore(paths: paths).definitionsDate() == nil)
        try FileManager.default.createDirectory(at: paths.databaseDirectory, withIntermediateDirectories: true)
        #expect(DefinitionsStore(paths: paths).definitionsDate() == nil)
    }

    @Test("the newest modification date among the known database files wins")
    func newestWins() throws {
        let temp = try TempDirectory()
        let paths = ClamAVPaths(supportDirectory: temp.url)
        let old = Date(timeIntervalSince1970: 1_700_000_000)
        let middle = Date(timeIntervalSince1970: 1_710_000_000)
        let newest = Date(timeIntervalSince1970: 1_720_000_000)
        try touch("main.cvd", in: paths, at: old)
        try touch("daily.cld", in: paths, at: newest)
        try touch("bytecode.cvd", in: paths, at: middle)
        let found = try #require(DefinitionsStore(paths: paths).definitionsDate())
        #expect(abs(found.timeIntervalSince(newest)) < 1)
    }

    @Test("a single file is enough, and unrelated or newer files are ignored")
    func ignoresUnrelated() throws {
        let temp = try TempDirectory()
        let paths = ClamAVPaths(supportDirectory: temp.url)
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        try touch("main.cld", in: paths, at: date)
        try touch("notes.txt", in: paths, at: Date(timeIntervalSince1970: 1_800_000_000))
        try touch("daily.cvd.tmp", in: paths, at: Date(timeIntervalSince1970: 1_800_000_000))
        let found = try #require(DefinitionsStore(paths: paths).definitionsDate())
        #expect(abs(found.timeIntervalSince(date)) < 1)
    }

    @Test("a directory named like a database file is ignored")
    func directoryIgnored() throws {
        let temp = try TempDirectory()
        let paths = ClamAVPaths(supportDirectory: temp.url)
        try FileManager.default.createDirectory(
            at: paths.databaseDirectory.appendingPathComponent("daily.cvd"), withIntermediateDirectories: true
        )
        #expect(DefinitionsStore(paths: paths).definitionsDate() == nil)
    }
}
