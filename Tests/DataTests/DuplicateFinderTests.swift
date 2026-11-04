import Foundation
@testable import MainternanceData
import MainternanceDomain
import Testing

/// The duplicate finder over a temp home. The minimum size is injected so tests write small files; the file that
/// must differ only in its middle is larger than the head and tail read together.
@Suite("Duplicate finder")
struct DuplicateFinderTests {
    @Test("the standard minimum is 1 MB and the head and tail read are 64 KiB each")
    func standardValues() throws {
        let fixture = try FilesFixture()
        #expect(DuplicateFinder(home: fixture.home, isProtected: { _ in false }).minimumBytes == 1_000_000)
        #expect(DuplicateFinder.edgeBytes == 65536)
        #expect(DuplicateFinder.chunkBytes == 65536)
    }

    @Test("three identical files and one of the same size that differs make one group of three")
    func threeOfFour() throws {
        let fixture = try FilesFixture()
        try fixture.write("Documents/b copy.pdf", pattern(5000))
        try fixture.write("Downloads/b.pdf", pattern(5000))
        try fixture.write("Desktop/b again.pdf", pattern(5000))
        try fixture.write("Desktop/other.pdf", pattern(5000, seed: 7))
        let run = fixture.findDuplicates()
        #expect(run.groups.count == 1)
        let group = try #require(run.groups.first)
        #expect(group.files.map(\.id) == [
            fixture.path("Desktop/b again.pdf"), fixture.path("Documents/b copy.pdf"), fixture.path("Downloads/b.pdf")
        ])
        #expect(isAbout(group.bytesEach, 5000))
        #expect(group.reclaimableBytes == group.bytesEach * 2)
        #expect(group.files.allSatisfy { $0.identity != nil && $0.kind == .document })
        #expect(run.outcome == DuplicateFinder.Outcome(unreadableFolders: 0, wasCancelled: false))
    }

    @Test("same size, same first and last 64 KiB, different middle: not duplicates")
    func differentMiddle() throws {
        let fixture = try FilesFixture()
        let size = 3 * 65536 + 123
        var changed = pattern(size)
        changed[size / 2] ^= 0xFF
        try fixture.write("A/one.bin", pattern(size))
        try fixture.write("B/two.bin", changed)
        let reads = Received<DuplicateFinder.Pass>()
        let run = fixture.findDuplicates(willRead: { pass, _ in reads.add(pass) })
        #expect(run.groups.isEmpty)
        // They did get past the head-and-tail comparison: only the whole file told them apart.
        #expect(reads.values.filter { $0 == .whole }.count == 2)
    }

    @Test("same size, different start: told apart by the head and tail, never read whole")
    func differentStart() throws {
        let fixture = try FilesFixture()
        var changed = pattern(5000)
        changed[0] ^= 0xFF
        try fixture.write("A/one.bin", pattern(5000))
        try fixture.write("B/two.bin", changed)
        let reads = Received<DuplicateFinder.Pass>()
        let run = fixture.findDuplicates(willRead: { pass, _ in reads.add(pass) })
        #expect(run.groups.isEmpty)
        #expect(reads.values == [.edges, .edges])
    }

    @Test("two names for the same file (hard links) are one file, never a group")
    func hardLinks() throws {
        let fixture = try FilesFixture()
        let first = try fixture.write("A/photo.jpg", pattern(5000))
        try FileManager.default.createDirectory(
            at: fixture.home.appendingPathComponent("B"), withIntermediateDirectories: true
        )
        try FileManager.default.linkItem(atPath: first.path, toPath: fixture.path("B/photo link.jpg"))
        try FileManager.default.linkItem(atPath: first.path, toPath: fixture.path("A/photo link 2.jpg"))
        #expect(fixture.findDuplicates().groups.isEmpty)
    }

    @Test("a hard-linked file and a real copy make a group of two: the copy and one name for the linked file")
    func hardLinkAndCopy() throws {
        let fixture = try FilesFixture()
        let first = try fixture.write("A/photo.jpg", pattern(5000))
        try FileManager.default.linkItem(atPath: first.path, toPath: fixture.path("A/photo link.jpg"))
        try fixture.write("C/photo copy.jpg", pattern(5000))
        let run = fixture.findDuplicates()
        let group = try #require(run.groups.first)
        #expect(run.groups.count == 1)
        #expect(group.files.count == 2)
        #expect(group.files.contains { $0.id == fixture.path("C/photo copy.jpg") })
        #expect(Set(group.files.compactMap(\.identity)).count == 2)
    }

    @Test("files under the minimum, and empty files, are ignored and never read")
    func underMinimum() throws {
        let fixture = try FilesFixture()
        try fixture.write("A/small.txt", pattern(999))
        try fixture.write("B/small.txt", pattern(999))
        try fixture.write("A/empty.txt", Data())
        try fixture.write("B/empty.txt", Data())
        try fixture.write("A/edge.txt", pattern(1000))
        try fixture.write("B/edge.txt", pattern(1000))
        let reads = Received<String>()
        let run = fixture.findDuplicates(willRead: { _, path in reads.add(path) })
        #expect(run.groups.map { $0.files.map(\.name) } == [["edge.txt", "edge.txt"]])
        #expect(Set(reads.values) == [fixture.path("A/edge.txt"), fixture.path("B/edge.txt")])
        // A minimum of zero still never groups empty files.
        let empty = try FilesFixture()
        try empty.write("A/empty.txt", Data())
        try empty.write("B/empty.txt", Data())
        #expect(empty.findDuplicates(minimum: 0).groups.isEmpty)
    }

    @Test("a file with a size no other file has is never read; no file is read twice in one pass")
    func readsBounded() throws {
        let fixture = try FilesFixture()
        try fixture.write("A/unique.bin", pattern(7000))
        for name in ["one", "two", "three"] {
            try fixture.write("B/\(name).bin", pattern(4 * 65536 + 9))
        }
        let reads = Received<String>()
        let run = fixture.findDuplicates(willRead: { pass, path in reads.add("\(pass) \(path)") })
        #expect(run.groups.count == 1)
        #expect(!reads.values.contains { $0.hasSuffix("unique.bin") })
        #expect(reads.values.count == 6)
        #expect(Set(reads.values).count == reads.values.count)
    }

    @Test("files inside packages, under Library and in dot-folders are not looked at")
    func walkerRules() throws {
        let fixture = try FilesFixture()
        try fixture.write("Documents/keep.bin", pattern(5000))
        try fixture.write("Library/Caches/keep.bin", pattern(5000))
        try fixture.write(".Trash/keep.bin", pattern(5000))
        try fixture.write("Applications/Tool.app/Contents/keep.bin", pattern(5000))
        try fixture.write("Applications/Tool copy.app/Contents/keep.bin", pattern(5000))
        #expect(fixture.findDuplicates().groups.isEmpty)
    }

    @Test("groups stream as they are confirmed, after a phase and before the end")
    func streams() async throws {
        let fixture = try FilesFixture()
        try fixture.write("A/x.bin", pattern(6000))
        try fixture.write("B/x.bin", pattern(6000))
        try fixture.write("A/y.bin", pattern(5000, seed: 3))
        try fixture.write("B/y.bin", pattern(5000, seed: 3))
        let updates = await collectDuplicateUpdates(fixture.finder().find())
        let kinds = updates.map(UpdateKind.init)
        #expect(kinds.first == .phase)
        #expect(kinds.last == .finished(unreadableFolders: 0, wasCancelled: false))
        #expect(kinds.filter { $0 == .group }.count == 2)
        let firstGroup = try #require(kinds.firstIndex(of: .group))
        #expect(kinds[..<firstGroup].contains(.phase))
        for update in updates {
            if case let .phase(text) = update {
                #expect(!text.isEmpty)
            }
        }
    }

    @Test("results are the same every time: biggest files first, files in a group by path")
    func deterministic() throws {
        let fixture = try FilesFixture()
        for folder in ["Z", "A", "M"] {
            try fixture.write("\(folder)/small.bin", pattern(2000))
            try fixture.write("\(folder)/big.bin", pattern(9000))
        }
        try fixture.write("Q/small-other.bin", pattern(2000, seed: 5))
        try fixture.write("R/small-other.bin", pattern(2000, seed: 5))
        let first = fixture.findDuplicates()
        let second = fixture.findDuplicates()
        #expect(first.groups == second.groups)
        #expect(first.groups.map { $0.files.map(\.name) } == [
            ["big.bin", "big.bin", "big.bin"], ["small.bin", "small.bin", "small.bin"],
            ["small-other.bin", "small-other.bin"]
        ])
        for group in first.groups {
            #expect(group.files.map(\.id) == group.files.map(\.id).sorted())
        }
        #expect(Set(first.groups.map(\.id)).count == 3)
    }
}
