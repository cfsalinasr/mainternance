import Foundation
@testable import MainternanceData
import MainternanceDomain
import Testing

/// Large files and the disk tree over a temp home. The size threshold is injected so tests write small files.
@Suite("Large file scanner")
struct LargeFileScannerTests {
    @Test("the standard threshold is 50 MB, the list is capped at 200 and folders keep 40 children")
    func standardValues() throws {
        let fixture = try FilesFixture()
        let scanner = LargeFileScanner(walker: fixture.walker())
        #expect(scanner.threshold == 50_000_000)
        #expect(scanner.limit == 200)
        #expect(LargeFileScanner.maxChildren == 40)
    }

    @Test("the largest list holds plain files at or above the threshold, largest first")
    func largestFirst() throws {
        let fixture = try FilesFixture()
        try fixture.file("Movies/big.mov", bytes: 300_000)
        try fixture.file("Documents/medium.pdf", bytes: 100_000)
        try fixture.file("Downloads/edge.zip", bytes: 40000)
        try fixture.file("Documents/small.txt", bytes: 1000)
        let result = fixture.scanner(threshold: 40000).run(shouldStop: { false }, progress: { _ in })
        #expect(result.largest.map(\.name) == ["big.mov", "medium.pdf", "edge.zip"])
        #expect(result.largest.map(\.id) == [
            fixture.path("Movies/big.mov"), fixture.path("Documents/medium.pdf"), fixture.path("Downloads/edge.zip")
        ])
        #expect(isAbout(result.largest[0].bytes, 300_000))
        #expect(isAbout(result.largest[1].bytes, 100_000))
        #expect(result.largest[0].kind == .video)
        #expect(result.largest.allSatisfy { $0.identity != nil })
        #expect(!result.wasCancelled)
        #expect(result.unreadableFolders == 0)
    }

    @Test("the largest list keeps only the biggest files up to its limit")
    func capped() throws {
        let fixture = try FilesFixture()
        for (index, size) in [30000, 90000, 50000, 70000, 110_000].enumerated() {
            try fixture.file("F/file\(index).bin", bytes: size)
        }
        let result = fixture.scanner(threshold: 20000, limit: 3).run(shouldStop: { false }, progress: { _ in })
        #expect(result.largest.map(\.name) == ["file4.bin", "file1.bin", "file3.bin"])
    }

    @Test("a package counts once in the tree and is never in the largest list")
    func packages() throws {
        let fixture = try FilesFixture()
        try fixture.file("Applications/Tool.app/Contents/MacOS/Tool", bytes: 200_000)
        try fixture.file("Applications/plain.bin", bytes: 30000)
        let result = fixture.scanner(threshold: 20000).run(shouldStop: { false }, progress: { _ in })
        #expect(result.largest.map(\.name) == ["plain.bin"])
        let apps = try #require(child("Applications", of: result.tree))
        let tool = try #require(child("Tool.app", of: apps))
        #expect(tool.isPackage)
        #expect(tool.children.isEmpty)
        #expect(!tool.isDrillable)
        #expect(isAbout(tool.bytes, 200_000))
        #expect(isAbout(apps.bytes, 230_000))
    }

    @Test("the tree sums sizes bottom-up; a folder keeps 40 children and an Other node for the rest")
    func treeAndOther() throws {
        let fixture = try FilesFixture()
        for index in 0 ..< 45 {
            try fixture.file("Many/f\(index).bin", bytes: 4096 * (index + 1))
        }
        try fixture.file("Docs/sub/a.txt", bytes: 8000)
        let result = fixture.scanner().run(shouldStop: { false }, progress: { _ in })
        let tree = result.tree
        #expect(tree.id == fixture.home.path)
        #expect(tree.isDrillable)
        let many = try #require(child("Many", of: tree))
        #expect(many.id == fixture.path("Many"))
        #expect(many.children.count == 41)
        let other = try #require(many.children.last)
        #expect(other.isOther)
        #expect(!other.isDrillable)
        #expect(many.children.dropLast().allSatisfy { !$0.isOther })
        #expect(many.children.dropLast().map(\.bytes) == many.children.dropLast().map(\.bytes).sorted(by: >))
        #expect(other.bytes == many.children.dropLast().reduce(many.bytes) { $0 - $1.bytes })
        // The five smallest files (4 KiB to 20 KiB written) make up Other.
        #expect(other.bytes >= 4096 * 15 && other.bytes < 4096 * 15 + 5 * 4096)
        let docs = try #require(child("Docs", of: tree))
        let sub = try #require(child("sub", of: docs))
        #expect(isAbout(sub.bytes, 8000))
        #expect(docs.bytes == sub.bytes)
        #expect(tree.bytes == many.bytes + docs.bytes)
        #expect(tree.children.map(\.name) == ["Many", "Docs"])
    }

    @Test("a hard-linked pair counts once")
    func hardLinks() throws {
        let fixture = try FilesFixture()
        let original = try fixture.file("A/original.bin", bytes: 100_000)
        try fixture.folder("B")
        try FileManager.default.linkItem(at: original, to: fixture.home.appendingPathComponent("B/twin.bin"))
        let result = fixture.scanner(threshold: 20000).run(shouldStop: { false }, progress: { _ in })
        #expect(result.largest.count == 1)
        #expect(isAbout(result.tree.bytes, 100_000))
    }

    @Test("folders that could not be read are counted")
    func unreadable() async throws {
        let fixture = try FilesFixture()
        let secret = try fixture.folder("Secret")
        try fixture.file("Secret/x.bin", bytes: 100)
        try fixture.file("Open/y.bin", bytes: 100)
        let result = await fixture.unreadable(secret) {
            fixture.scanner().run(shouldStop: { false }, progress: { _ in })
        }
        #expect(result.unreadableFolders == 1)
    }

    @Test("odd names are kept exactly as on disk and display safely")
    func oddNames() throws {
        let fixture = try FilesFixture()
        try fixture.file("Odd/-rf evil\u{202E}gpj.mov\nx", bytes: 30000)
        let result = fixture.scanner(threshold: 20000).run(shouldStop: { false }, progress: { _ in })
        let item = try #require(result.largest.first)
        #expect(item.id == fixture.path("Odd/-rf evil\u{202E}gpj.mov\nx"))
        #expect(item.displayName == "-rf evilgpj.mov x")
    }

    @Test("the stream reports progress, then the finished result, then ends")
    func streamProgress() async throws {
        let fixture = try FilesFixture()
        for index in 0 ..< 10 {
            try fixture.file("F/f\(index).bin", bytes: 30000)
        }
        let updates = await collectUpdates(fixture.scanner(progressEvery: 3).scan())
        let counts = updates.compactMap { update -> Int? in
            if case let .progress(scanned) = update {
                return scanned
            }
            return nil
        }
        #expect(counts == [3, 6, 9])
        guard case let .finished(result) = updates.last else {
            Issue.record("the last update is not the finished result")
            return
        }
        #expect(result.largest.count == 10)
        #expect(!result.wasCancelled)
    }

    @Test("asking it to stop ends the walk promptly and marks the result cancelled")
    func stopRequested() throws {
        let fixture = try FilesFixture()
        for index in 0 ..< 200 {
            try fixture.file("F/f\(index).bin", bytes: 30000)
        }
        var scanned = 0
        let result = fixture.scanner(threshold: 20000, progressEvery: 1).run(
            shouldStop: { scanned >= 5 }, progress: { scanned = $0 }
        )
        #expect(result.wasCancelled)
        #expect(result.largest.count == 5)
    }

    @Test("cancelling the consuming task stops the walk promptly and finishes it as cancelled")
    func cancellingConsumer() async throws {
        let fixture = try FilesFixture()
        for index in 0 ..< 1000 {
            try fixture.file("F/\(index % 20)/f\(index).bin", bytes: 10)
        }
        let ended = Received<DiskScanResult>()
        // Each item takes at least 2 ms, so a full walk takes at least 2 s: far longer than cancelling takes.
        let slow = fixture.walker(volume: { _, info in
            usleep(2000)
            return info.device
        })
        // Every file is "large" here, so the list shows how far the walk got.
        let scanner = fixture.scanner(
            walker: slow, threshold: 1, limit: 5000, progressEvery: 1, ended: { ended.add($0) }
        )
        let consumer = Task {
            for await update in scanner.scan() {
                if case .progress = update {
                    withUnsafeCurrentTask { $0?.cancel() }
                }
            }
        }
        await consumer.value
        let deadline = Date().addingTimeInterval(10)
        while ended.values.isEmpty, Date() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let result = try #require(ended.values.first)
        #expect(result.wasCancelled)
        #expect(result.largest.count < 250)
    }

    @Test("the tree builder holds only the folders being walked, never every file")
    func treeMemoryBounded() throws {
        let fixture = try FilesFixture()
        for folder in 0 ..< 60 {
            for file in 0 ..< 5 {
                try fixture.file("Top/F\(folder)/sub/f\(file).bin", bytes: 4096 * (file + 1))
            }
            try fixture.file("Top/F\(folder)/own.bin", bytes: 4096)
        }
        let builder = DiskTreeBuilder(root: fixture.home.path, maxChildren: 4)
        for file in fixture.walk().files {
            builder.add(file)
        }
        let tree = builder.build()
        // 360 files went in; open folders (home, Top, one F, its sub) hold at most 2 x 4 entries each.
        #expect(builder.peakHeldEntries <= 4 * 2 * 4)
        let top = try #require(child("Top", of: tree))
        #expect(top.children.count == 5)
        #expect(top.children.last?.isOther == true)
        #expect(top.bytes == CleanupMath.sum(top.children.map(\.bytes)))
        #expect(top.bytes == 60 * 4096 * 16)
        #expect(tree.bytes == top.bytes)
        let first = try #require(top.children.first)
        #expect(first.id.hasPrefix(fixture.path("Top/F")))
        let sub = try #require(child("sub", of: first))
        #expect(sub.id == first.id + "/sub")
        #expect(sub.children.map(\.name) == ["f4.bin", "f3.bin", "f2.bin", "f1.bin", "Other"])
        #expect(sub.children.first?.id == sub.id + "/f4.bin")
    }
}
