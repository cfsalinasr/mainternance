import Foundation
@testable import MainternanceData
import MainternanceDomain
import Testing

/// What the searcher does with Spotlight's answer, with a fake `runQuery`. The real `runSpotlight` is never called.
@Suite("Spotlight searcher")
struct SpotlightSearcherTests {
    private func searcher(
        _ fixture: FilesFixture, paths: @escaping @Sendable () -> [String], seen: Received<Int>? = nil
    ) -> SpotlightSearcher {
        SpotlightSearcher(home: fixture.home) { _, _, limit in
            seen?.add(limit)
            return SpotlightAnswer(paths: paths())
        }
    }

    private func setModified(_ url: URL, _ seconds: TimeInterval) throws {
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: seconds)], ofItemAtPath: url.path
        )
    }

    @Test("an empty query returns nothing and never runs a query")
    func emptyQuery() async throws {
        let fixture = try FilesFixture()
        let calls = Received<Int>()
        let result = await searcher(fixture, paths: { [] }, seen: calls).search(FileSearchQuery())
        #expect(result.files.isEmpty)
        #expect(!result.isTruncated)
        #expect(calls.values.isEmpty)
    }

    @Test("the query is built from the filters and run against the home folder")
    func runsWithPredicate() async throws {
        let fixture = try FilesFixture()
        let seen = Received<String>()
        let found = SpotlightSearcher(home: fixture.home) { predicate, home, _ in
            seen.add(((predicate as? NSComparisonPredicate)?.rightExpression.constantValue as? String) ?? "?")
            seen.add(home.path)
            return SpotlightAnswer(paths: [])
        }
        _ = await found.search(FileSearchQuery(text: "tax"))
        #expect(seen.values == ["tax", fixture.home.path])
    }

    @Test("real files come back newest first, re-read from disk")
    func newestFirst() async throws {
        let fixture = try FilesFixture()
        let old = try fixture.file("Documents/old.txt", bytes: 3000)
        let mid = try fixture.file("Documents/mid.txt", bytes: 1000)
        let new = try fixture.file("Desktop/new.txt", bytes: 2000)
        try setModified(old, 1_000_000)
        try setModified(mid, 2_000_000)
        try setModified(new, 3_000_000)
        let paths = [mid.path, old.path, new.path]
        let result = await searcher(fixture, paths: { paths }).search(FileSearchQuery(text: "txt"))
        #expect(result.files.map(\.name) == ["new.txt", "mid.txt", "old.txt"])
        #expect(result.files.map(\.modified.timeIntervalSince1970) == [3_000_000, 2_000_000, 1_000_000])
        #expect(result.files.allSatisfy { $0.bytes >= 1000 && $0.identity != nil && $0.kind == .document })
        #expect(!result.isTruncated)
    }

    @Test("results under Library, dot-folders and the Trash are dropped")
    func excludedFolders() async throws {
        let fixture = try FilesFixture()
        let keep = try fixture.file("Documents/keep.txt")
        let paths = try [
            keep.path,
            fixture.file("Library/Caches/a.txt").path,
            fixture.file("Library/Mail/b.txt").path,
            fixture.file(".Trash/c.txt").path,
            fixture.file(".config/d.txt").path,
            fixture.file("Projects/.git/e.txt").path,
            fixture.file("Documents/.hidden.txt").path
        ]
        let result = await searcher(fixture, paths: { paths }).search(FileSearchQuery(text: "txt"))
        #expect(result.files.map(\.id) == [keep.path])
    }

    @Test("a folder merely named Library deeper down is kept")
    func deeperLibrary() async throws {
        let fixture = try FilesFixture()
        let deep = try fixture.file("Documents/Library/notes.txt")
        let result = await searcher(fixture, paths: { [deep.path] }).search(FileSearchQuery(text: "n"))
        #expect(result.files.map(\.id) == [deep.path])
    }

    @Test("links, folders and vanished files are dropped")
    func notPlainFiles() async throws {
        let fixture = try FilesFixture()
        let real = try fixture.file("Documents/real.txt")
        let link = try fixture.link("Documents/link.txt", to: real.path)
        let folder = try fixture.folder("Documents/folder.txt")
        let gone = fixture.path("Documents/gone.txt")
        let paths = [real.path, link.path, folder.path, gone]
        let result = await searcher(fixture, paths: { paths }).search(FileSearchQuery(text: "txt"))
        #expect(result.files.map(\.id) == [real.path])
    }

    @Test("a file reached through a linked folder is dropped when it is really outside home")
    func linkedFolderOutside() async throws {
        let fixture = try FilesFixture()
        let outside = try FileManager.default.url(
            for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: fixture.temp.url, create: true
        )
        defer { try? FileManager.default.removeItem(at: outside) }
        let target = outside.appendingPathComponent("secret.txt")
        try Data("x".utf8).write(to: target)
        try fixture.link("Shortcut", to: outside.path)
        let viaLink = fixture.path("Shortcut/secret.txt")
        let result = await searcher(fixture, paths: { [viaLink, target.path] }).search(FileSearchQuery(text: "s"))
        #expect(result.files.isEmpty)
    }

    @Test("a path outside the home folder is dropped, also with dots in it and a lookalike prefix")
    func outsideHome() async throws {
        let fixture = try FilesFixture()
        let sibling = fixture.temp.url.appendingPathComponent("home2", isDirectory: true)
        try FileManager.default.createDirectory(at: sibling, withIntermediateDirectories: true)
        let lookalike = sibling.appendingPathComponent("a.txt")
        try Data("x".utf8).write(to: lookalike)
        let escaping = fixture.path("Documents/../../home2/a.txt")
        try fixture.folder("Documents")
        let result = await searcher(fixture, paths: { [lookalike.path, escaping, "relative.txt", ""] })
            .search(FileSearchQuery(text: "a"))
        #expect(result.files.isEmpty)
    }

    @Test("a home folder reached through a link still matches resolved results")
    func linkedHome() async throws {
        let fixture = try FilesFixture()
        let file = try fixture.file("Documents/a.txt")
        let alias = fixture.temp.url.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(atPath: alias.path, withDestinationPath: fixture.home.path)
        let viaAlias = alias.appendingPathComponent("Documents/a.txt").path
        let found = SpotlightSearcher(home: alias) { _, _, _ in SpotlightAnswer(paths: [viaAlias, file.path]) }
        let result = await found.search(FileSearchQuery(text: "a"))
        #expect(result.files.map(\.id) == [file.path])
    }

    @Test("the same file reported twice appears once")
    func duplicatesDropped() async throws {
        let fixture = try FilesFixture()
        let file = try fixture.file("Documents/a.txt")
        let result = await searcher(fixture, paths: { [file.path, file.path] }).search(FileSearchQuery(text: "a"))
        #expect(result.files.count == 1)
    }

    @Test("more than 500 results are capped at 500, newest first, and marked truncated")
    func capped() async throws {
        let fixture = try FilesFixture()
        var paths: [String] = []
        for index in 0 ..< 505 {
            let url = try fixture.file("Documents/f\(index).txt", bytes: 10)
            try setModified(url, TimeInterval(1_000_000 + index))
            paths.append(url.path)
        }
        let all = paths
        let result = await searcher(fixture, paths: { all }).search(FileSearchQuery(text: "f"))
        #expect(result.files.count == 500)
        #expect(result.isTruncated)
        #expect(result.files.first?.name == "f504.txt")
        #expect(result.files.last?.name == "f5.txt")
    }

    @Test("exactly 500 results are not truncated")
    func exactlyCap() async throws {
        let fixture = try FilesFixture()
        var paths: [String] = []
        for index in 0 ..< 500 {
            try paths.append(fixture.file("Documents/f\(index).txt", bytes: 10).path)
        }
        let all = paths
        let result = await searcher(fixture, paths: { all }).search(FileSearchQuery(text: "f"))
        #expect(result.files.count == 500)
        #expect(!result.isTruncated)
    }

    @Test("a query that hit its fetch limit is truncated even when few results survive")
    func fetchLimitReached() async throws {
        let fixture = try FilesFixture()
        let file = try fixture.file("Documents/a.txt")
        let junk = (0 ..< SpotlightSearcher.fetchLimit - 1).map { _ in fixture.path("Library/x.txt") }
        let all = [file.path] + junk
        let result = await searcher(fixture, paths: { all }).search(FileSearchQuery(text: "a"))
        #expect(result.files.count == 1)
        #expect(result.isTruncated)
    }

    @Test("a cancelled search returns nothing")
    func cancelled() async throws {
        let fixture = try FilesFixture()
        let file = try fixture.file("Documents/a.txt")
        let found = SpotlightSearcher(home: fixture.home) { _, _, _ in
            while !Task.isCancelled {
                await Task.yield()
            }
            return SpotlightAnswer(paths: [file.path])
        }
        let task = Task { await found.search(FileSearchQuery(text: "a")) }
        task.cancel()
        let result = await task.value
        #expect(result.files.isEmpty)
    }

    @Test("a run that could not answer gives no files and says so; an ordinary empty answer does not")
    func unavailable() async throws {
        let fixture = try FilesFixture()
        let file = try fixture.file("Documents/a.txt")
        let down = SpotlightSearcher(home: fixture.home) { _, _, _ in
            SpotlightAnswer(paths: [file.path], isUnavailable: true)
        }
        let failed = await down.search(FileSearchQuery(text: "a"))
        #expect(failed.files.isEmpty)
        #expect(failed.isUnavailable)
        let empty = await searcher(fixture, paths: { [] }).search(FileSearchQuery(text: "a"))
        #expect(!empty.isUnavailable)
        let none = await searcher(fixture, paths: { [] }).search(FileSearchQuery())
        #expect(!none.isUnavailable)
    }
}

/// The timeout logic of the real run, with a fake clock: no Spotlight query is made.
@Suite("Spotlight deadline")
struct SpotlightDeadlineTests {
    @Test("work that finishes first gives its value")
    func finishesFirst() async {
        let value = await SpotlightDeadline.race(
            seconds: 30, sleep: { _ in try await Task.sleep(for: .seconds(60)) }, work: { 7 }
        )
        #expect(value == 7)
    }

    @Test("a deadline that passes first gives nil and cancels the work")
    func timesOut() async {
        let cancelled = Received<Bool>()
        let value: Int? = await SpotlightDeadline.race(seconds: 30, sleep: { _ in }, work: {
            while !Task.isCancelled {
                await Task.yield()
            }
            cancelled.add(true)
            return 1
        })
        #expect(value == nil)
        #expect(cancelled.values == [true])
    }

    @Test("the real deadline is 30 seconds")
    func thirty() {
        #expect(SpotlightSearcher.timeoutSeconds == 30)
    }

    @Test("cancelling the caller gives the work's own answer, not a timeout")
    func callerCancelled() async {
        let task = Task {
            await SpotlightDeadline.race(seconds: 30, sleep: { _ in try await Task.sleep(for: .seconds(60)) }, work: {
                while !Task.isCancelled {
                    await Task.yield()
                }
                return 5
            })
        }
        task.cancel()
        #expect(await task.value == 5)
    }
}
