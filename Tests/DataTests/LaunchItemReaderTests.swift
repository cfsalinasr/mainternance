import Darwin
import Foundation
@testable import MainternanceData
import MainternanceDomain
import Testing

/// Reading launchd property lists from temp folders: every file becomes a row, a bad one says why.
@Suite("Launch item reader")
struct LaunchItemReaderTests {
    @Test("a user agent with a label, arguments and RunAtLoad becomes a row")
    func validAgent() throws {
        let fixture = try StartupFixture()
        let path = try fixture.plist("com.example.updater.plist", in: fixture.userFolder, [
            "Label": "com.example.updater",
            "ProgramArguments": ["/Applications/Example.app/Contents/MacOS/updater", "--quiet"],
            "RunAtLoad": true
        ])
        let result = fixture.reader.read()
        let item = try #require(result.items.first)
        #expect(result.items.count == 1)
        #expect(item.id == path)
        #expect(item.plistPath == path)
        #expect(item.label == "com.example.updater")
        #expect(item.name == "updater")
        #expect(item.kind == .userAgent)
        #expect(item.program == "/Applications/Example.app/Contents/MacOS/updater")
        #expect(item.runsAtLoad == true)
        #expect(item.readProblem == nil)
        #expect(item.isEnabled == nil) // the reader knows nothing about launchd's state
        #expect(item.canToggle)
    }

    @Test("Program wins over ProgramArguments; a binary property list reads the same")
    func programKeyWins() throws {
        let fixture = try StartupFixture()
        try fixture.plist("b.plist", in: fixture.daemonFolder, [
            "Label": "com.example.b", "Program": "/usr/local/bin/b", "ProgramArguments": ["/other", "-x"],
            "RunAtLoad": false
        ], binary: true)
        let item = try #require(fixture.reader.read().items.first)
        #expect(item.program == "/usr/local/bin/b")
        #expect(item.runsAtLoad == false)
        #expect(item.kind == .systemDaemon)
        #expect(!item.canToggle)
    }

    @Test("a file without Label, Program or ProgramArguments is still a row, named after the file")
    func missingKeys() throws {
        let fixture = try StartupFixture()
        try fixture.plist("Mystery.plist", in: fixture.userFolder, ["KeepAlive": true, "Label": 42])
        let item = try #require(fixture.reader.read().items.first)
        #expect(item.label == nil)
        #expect(item.name == "Mystery")
        #expect(item.program == nil)
        #expect(item.runsAtLoad == nil)
        #expect(item.readProblem == nil)
        #expect(!item.canToggle)
    }

    @Test("empty, malformed, non-dictionary and oversized files become 'could not be read' rows")
    func unreadableFiles() throws {
        let fixture = try StartupFixture()
        let folder = fixture.agentFolder
        try fixture.raw("empty.plist", in: folder, Data())
        try fixture.raw("garbage.plist", in: folder, Data("<plist><dict><key>Label".utf8))
        let array = try PropertyListSerialization.data(fromPropertyList: ["a", "b"], format: .xml, options: 0)
        try fixture.raw("array.plist", in: folder, array)
        try fixture.raw("huge.plist", in: folder, Data(count: LaunchItemReader.maxBytes + 1))
        let items = fixture.reader.read().items
        #expect(items.map(\.name) == ["array", "empty", "garbage", "huge"])
        for item in items {
            let problem = try #require(item.readProblem)
            #expect(problem.hasPrefix("Could not be read"))
            #expect(item.kind == .systemAgent)
            #expect(item.label == nil)
        }
        #expect(items.first { $0.name == "huge" }?.readProblem?.contains("1 MB") == true)
        #expect(items.first { $0.name == "array" }?.readProblem?.contains("dictionary") == true)
    }

    @Test("a folder named like a plist and a FIFO are rows that could not be read; reading never blocks")
    func notRegularFiles() async throws {
        let fixture = try StartupFixture()
        try FileManager.default.createDirectory(
            at: fixture.userFolder.appendingPathComponent("folder.plist"), withIntermediateDirectories: true
        )
        let fifo = fixture.userFolder.appendingPathComponent("pipe.plist").path
        #expect(mkfifo(fifo, 0o600) == 0)
        let reader = fixture.reader
        let items = await within(5, "reading a FIFO must not block") { reader.read().items }
        let rows = try #require(items)
        #expect(rows.map(\.name) == ["folder", "pipe"])
        #expect(rows.allSatisfy { $0.readProblem?.contains("not a regular file") == true })
    }

    @Test("a symlinked plist appears once, under the link's own path; files that are not plists are not listed")
    func symlinks() throws {
        let fixture = try StartupFixture()
        let outside = fixture.temp.url.appendingPathComponent("elsewhere", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let target = try fixture.job("com.example.linked", in: outside)
        let link = fixture.userFolder.appendingPathComponent("com.example.linked.plist")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: target)
        try fixture.raw("README.txt", in: fixture.userFolder, Data("not a job".utf8))
        let items = fixture.reader.read().items
        #expect(items.count == 1)
        #expect(items.first?.plistPath == link.path)
        #expect(items.first?.label == "com.example.linked")
    }

    @Test("rows are sorted by kind, then by name")
    func sorting() throws {
        let fixture = try StartupFixture()
        try fixture.job("com.z.daemon", in: fixture.daemonFolder)
        try fixture.job("com.b.agent", in: fixture.agentFolder)
        try fixture.job("com.y.zeta", in: fixture.userFolder)
        try fixture.job("com.x.Alpha", in: fixture.userFolder)
        let items = fixture.reader.read().items
        #expect(items.map(\.name) == ["Alpha", "zeta", "agent", "daemon"])
        #expect(items.map(\.kind) == [.userAgent, .userAgent, .systemAgent, .systemDaemon])
    }

    @Test("a missing folder lists nothing; a folder that cannot be opened is reported, not skipped")
    func folders() throws {
        let fixture = try StartupFixture()
        try FileManager.default.removeItem(at: fixture.agentFolder)
        let manager = FileManager.default
        try manager.setAttributes([.posixPermissions: 0o000], ofItemAtPath: fixture.daemonFolder.path)
        defer { try? manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fixture.daemonFolder.path) }
        let result = fixture.reader.read()
        #expect(result.items.isEmpty)
        #expect(result.unreadableFolders == [fixture.daemonFolder.path])
    }

    @Test("the standard folders are the user's agents, agents for all users and system daemons")
    func standardSources() {
        let home = URL(fileURLWithPath: "/Users/someone", isDirectory: true)
        let sources = LaunchItemReader.standardSources(home: home)
        #expect(sources.map(\.folder.path) == [
            "/Users/someone/Library/LaunchAgents", "/Library/LaunchAgents", "/Library/LaunchDaemons"
        ])
        #expect(sources.map(\.kind) == [.userAgent, .systemAgent, .systemDaemon])
    }
}
