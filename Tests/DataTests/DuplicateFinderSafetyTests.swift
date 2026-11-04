import Foundation
@testable import MainternanceData
import MainternanceDomain
import Testing

/// The duplicate finder when asked to stop, and when files or folders change or cannot be read during a search.
/// Temp home only.
@Suite("Duplicate finder safety")
struct DuplicateFinderSafetyTests {
    @Test("asked to stop, the search stops at once and reports no groups it did not finish")
    func stopsWhenAsked() throws {
        let fixture = try FilesFixture()
        for index in 0 ..< 6 {
            try fixture.write("A/\(index).bin", pattern(3000 + index))
            try fixture.write("B/\(index).bin", pattern(3000 + index))
        }
        let reads = Received<String>()
        var checks = 0
        var groups: [DuplicateGroup] = []
        let outcome = fixture.finder(willRead: { _, path in reads.add(path) }).run(
            shouldStop: {
                checks += 1
                return reads.values.count >= 3
            },
            phase: { _ in },
            group: { groups.append($0) }
        )
        #expect(outcome.wasCancelled)
        #expect(reads.values.count == 3)
        // The stop came during the first pair's whole read: that pair was never confirmed, so nothing is reported.
        #expect(groups.isEmpty)
    }

    @Test("cancelling the stream while files are being compared stops the reading promptly")
    func cancelPromptly() async throws {
        let fixture = try FilesFixture()
        // One length, 40 identical files of four chunks: uncancelled, 80 opens and 160 chunks at 20 ms each would
        // take about five seconds, all inside one length (so only the checks during reading can stop it).
        for index in 0 ..< 40 {
            try fixture.write("\(index % 2 == 0 ? "A" : "B")/\(index).bin", pattern(3 * 65536 + 100))
        }
        let ended = Received<DuplicateFinder.Outcome>()
        let reads = Received<String>()
        let chunks = Received<String>()
        let finder = fixture.finder(
            willRead: { _, path in
                reads.add(path)
                usleep(20000)
            },
            didReadChunk: { path in
                chunks.add(path)
                usleep(20000)
            },
            ended: { ended.add($0) }
        )
        let consumer = Task {
            // The walk is over once comparing starts: the cancel lands while files are being read.
            for await update in finder.find() {
                if case let .phase(text) = update, text.hasPrefix("Comparing") {
                    break
                }
            }
        }
        await consumer.value
        let start = Date()
        while ended.values.isEmpty, Date().timeIntervalSince(start) < 5 {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(Date().timeIntervalSince(start) < 2)
        #expect(ended.values.first?.wasCancelled == true)
        #expect(reads.values.count < 10)
        #expect(chunks.values.count < 10)
    }

    @Test("a file changed while it is being read whole is dropped from its group")
    func changedDuringWholeRead() throws {
        let fixture = try FilesFixture()
        let size = 3 * 65536 + 500
        for name in ["a", "b", "c"] {
            try fixture.write("D/\(name).bin", pattern(size))
        }
        let touched = fixture.path("D/b.bin")
        let chunks = Received<String>()
        let run = fixture.findDuplicates(didReadChunk: { path in
            chunks.add(path)
            // After its first chunk: same contents, new modified date. Only the check after reading can see it.
            guard path == touched, chunks.values.filter({ $0 == touched }).count == 1 else { return }
            var times = [timeval(tv_sec: 2_000_000_000, tv_usec: 0), timeval(tv_sec: 2_000_000_000, tv_usec: 0)]
            utimes(path, &times)
        })
        #expect(chunks.values.filter { $0 == touched }.count == 4)
        #expect(run.groups.map { $0.files.map(\.name) } == [["a.bin", "c.bin"]])
    }

    @Test("a file that becomes unreadable before its whole read is dropped from its group, never reported")
    func unreadableMidHash() throws {
        let fixture = try FilesFixture()
        for name in ["a", "b", "c"] {
            try fixture.write("D/\(name).bin", pattern(5000))
        }
        let locked = fixture.path("D/b.bin")
        let run = fixture.findDuplicates(willRead: { pass, path in
            if pass == .whole, path == locked {
                chmod(path, 0)
            }
        })
        chmod(locked, 0o644)
        #expect(run.groups.map { $0.files.map(\.name) } == [["a.bin", "c.bin"]])
        #expect(run.outcome.unreadableFolders == 0)
    }

    @Test("a group left with one readable copy is not reported")
    func unreadableLeavesOne() throws {
        let fixture = try FilesFixture()
        try fixture.write("D/a.bin", pattern(5000))
        try fixture.write("D/b.bin", pattern(5000))
        let locked = fixture.path("D/a.bin")
        let run = fixture.findDuplicates(willRead: { pass, path in
            if pass == .edges, path == locked {
                chmod(path, 0)
            }
        })
        chmod(locked, 0o644)
        #expect(run.groups.isEmpty)
    }

    @Test("a file removed, changed, or swapped for a link after the walk is dropped")
    func changedAfterWalk() throws {
        let fixture = try FilesFixture()
        for name in ["a", "b", "c", "d", "e"] {
            try fixture.write("D/\(name).bin", pattern(5000))
        }
        let removed = fixture.path("D/b.bin")
        let linked = fixture.path("D/c.bin")
        let rewritten = fixture.path("D/d.bin")
        let original = fixture.path("D/a.bin")
        let run = fixture.findDuplicates(willRead: { pass, path in
            guard pass == .whole else { return }
            if path == removed {
                try? FileManager.default.removeItem(atPath: path)
            } else if path == linked {
                // A link to an identical copy: following it would make a false pair.
                try? FileManager.default.removeItem(atPath: path)
                try? FileManager.default.createSymbolicLink(atPath: path, withDestinationPath: original)
            } else if path == rewritten {
                // Same size, new contents written in place (same file): its modified date moves on.
                let handle = FileHandle(forWritingAtPath: path)
                handle?.write(pattern(5000))
                try? handle?.close()
                var times = [timeval(tv_sec: 2_000_000_000, tv_usec: 0), timeval(tv_sec: 2_000_000_000, tv_usec: 0)]
                utimes(path, &times)
            }
        })
        #expect(run.groups.map { $0.files.map(\.name) } == [["a.bin", "e.bin"]])
    }

    @Test("folders that cannot be read are counted in the end report")
    func unreadableFolders() async throws {
        let fixture = try FilesFixture()
        let locked = try fixture.folder("Private")
        try fixture.write("Private/a.bin", pattern(5000))
        try fixture.write("Open/a.bin", pattern(5000))
        try fixture.write("Open/b.bin", pattern(5000))
        let updates = await fixture.unreadable(locked) {
            await collectDuplicateUpdates(fixture.finder().find())
        }
        #expect(updates.map(UpdateKind.init).last == .finished(unreadableFolders: 1, wasCancelled: false))
        #expect(updates.compactMap(\.group).map { $0.files.map(\.name) } == [["a.bin", "b.bin"]])
    }
}
