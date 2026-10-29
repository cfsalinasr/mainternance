import Foundation
@testable import MainternancePresentation
import Testing

struct FilesSampleDataTests {
    @Test func sampleDataIsNonEmpty() {
        #expect(!FilesSampleData.files.isEmpty)
        #expect(!FilesSampleData.duplicates.isEmpty)
        #expect(!FilesSampleData.largest.isEmpty)
        #expect(FilesSampleData.treemap.size > 0)
    }

    @Test func duplicateGroupsHaveTwoOrMoreEqualSizedFiles() {
        for group in FilesSampleData.duplicates {
            #expect(group.files.count >= 2)
            #expect(Set(group.files.map(\.size)).count == 1)
        }
    }

    @Test func largestIsSortedDescending() {
        let sizes = FilesSampleData.largest.map(\.size)
        #expect(sizes == sizes.sorted(by: >))
    }

    @Test func fileSizeTextHandlesZero() {
        #expect(formatFileSize(0) == "Empty")
        #expect(formatFileSize(-5) == "Empty")
        #expect(formatFileSize(1_000_000) != "Empty")
    }
}

struct FileSearchTests {
    private let now = Date(timeIntervalSince1970: 2_000_000_000)
    private func file(_ path: String, size: Int64 = 10, daysAgo: Double = 1, kind: FileKind = .document) -> SampleFile {
        SampleFile(
            name: (path as NSString).lastPathComponent, path: path, size: size,
            modified: now.addingTimeInterval(-daysAgo * 86400), kind: kind
        )
    }

    private func names(_ files: [SampleFile], _ criteria: FileSearchCriteria) -> [String] {
        FileSearch.filter(files, criteria: criteria, now: now).map(\.name)
    }

    @Test func emptyQueryReturnsEverything() {
        let files = [file("/a/b.txt"), file("/c/d.txt")]
        #expect(names(files, FileSearchCriteria()).count == 2)
    }

    @Test func matchesNameAndPathCaseInsensitively() {
        let files = [file("/Users/Report.PDF"), file("/projects/alpha/x.txt"), file("/other/y.txt")]
        #expect(names(files, FileSearchCriteria(text: "report")) == ["Report.PDF"])
        #expect(names(files, FileSearchCriteria(text: "ALPHA")) == ["x.txt"])
        #expect(names(files, FileSearchCriteria(text: "zzz")).isEmpty)
    }

    @Test func kindSizeAndDateFiltersApply() {
        let files = [
            file("/a/img.png", size: 5_000_000, daysAgo: 2, kind: .image),
            file("/a/doc.txt", size: 10, daysAgo: 2, kind: .document),
            file("/a/old.png", size: 5_000_000, daysAgo: 400, kind: .image)
        ]
        #expect(names(files, FileSearchCriteria(kind: .image)) == ["img.png", "old.png"])
        #expect(names(files, FileSearchCriteria(size: .over1MB)) == ["img.png", "old.png"])
        #expect(names(files, FileSearchCriteria(date: .pastMonth)) == ["img.png", "doc.txt"])
        #expect(names(files, FileSearchCriteria(kind: .image, size: .over1MB, date: .pastWeek)) == ["img.png"])
    }

    @Test func sampleFiltersActuallyNarrowSampleData() {
        let all = FilesSampleData.files
        #expect(FileSearch.filter(all, criteria: FileSearchCriteria(size: .over1GB)).count < all.count)
        #expect(FileSearch.filter(all, criteria: FileSearchCriteria(kind: .video)).count == 2)
        #expect(FileSearch.filter(all, criteria: FileSearchCriteria(date: .pastDay)).count < all.count)
    }
}

struct KeepRuleTests {
    private let base = Date(timeIntervalSince1970: 1_000_000)
    private func file(_ path: String, _ offset: TimeInterval) -> SampleFile {
        SampleFile(name: path, path: path, size: 1, modified: base.addingTimeInterval(offset), kind: .other)
    }

    @Test func newestKeepsLatest() {
        let group = [file("/a", 0), file("/b", 100), file("/c", 50)]
        let selection = DuplicateSelection(group: group, rule: .newest)
        #expect(selection.kept?.path == "/b")
        #expect(selection.removable.count == 2)
    }

    @Test func oldestKeepsEarliest() {
        let group = [file("/a", 10), file("/b", 100), file("/c", 5)]
        #expect(DuplicateSelection(group: group, rule: .oldest).kept?.path == "/c")
    }

    @Test func shortestPathKeepsShortest() {
        let group = [file("/long/path/x", 0), file("/s", 100), file("/mid/x", 50)]
        #expect(DuplicateSelection(group: group, rule: .shortestPath).kept?.path == "/s")
    }

    @Test func tiesBreakDeterministically() {
        let group = [file("/bb", 0), file("/aa", 0)]
        #expect(DuplicateSelection(group: group, rule: .newest).kept?.path == "/aa")
        #expect(DuplicateSelection(group: group.reversed(), rule: .shortestPath).kept?.path == "/aa")
        let longerOlder = [file("/long/one", 0), file("/s", 0)]
        #expect(DuplicateSelection(group: longerOlder, rule: .oldest).kept?.path == "/s")
    }

    @Test func emptyGroupAndReclaimable() {
        #expect(DuplicateSelection(group: [], rule: .newest).kept == nil)
        let selection = DuplicateSelection(group: [file("/a", 0), file("/b", 1), file("/c", 2)], rule: .newest)
        #expect(selection.reclaimableBytes == 2)
        #expect(selection.isKept(file("/c", 2)))
    }
}

struct TreemapLayoutTests {
    private let container = CGRect(x: 10, y: 20, width: 400, height: 300)
    private let eps: CGFloat = 0.001

    private let items = [
        TreemapItem(id: "a", size: 600), TreemapItem(id: "b", size: 300), TreemapItem(id: "c", size: 200),
        TreemapItem(id: "d", size: 100), TreemapItem(id: "e", size: 50), TreemapItem(id: "f", size: 50)
    ]

    @Test func emptyInputGivesEmptyOutput() {
        #expect(TreemapLayout.layout([], in: container).isEmpty)
        #expect(TreemapLayout.layout(items, in: .zero).isEmpty)
    }

    @Test func zeroAndNegativeSizesAreIgnored() {
        let tiles = TreemapLayout.layout(
            [TreemapItem(id: "z", size: 0), TreemapItem(id: "n", size: -4), TreemapItem(id: "ok", size: 5)],
            in: container
        )
        #expect(tiles.map(\.id) == ["ok"])
        #expect(TreemapLayout.layout([TreemapItem(id: "z", size: 0)], in: container).isEmpty)
    }

    @Test func areasAreProportional() throws {
        let tiles = TreemapLayout.layout(items, in: container)
        #expect(tiles.count == items.count)
        let total = Double(items.reduce(0) { $0 + $1.size })
        for tile in tiles {
            let size = try Double(#require(items.first { $0.id == tile.id }?.size))
            let expected = Double(container.width * container.height) * size / total
            #expect(abs(Double(tile.rect.width * tile.rect.height) - expected) < 0.01)
        }
    }

    @Test func tilesStayInsideAndDoNotOverlap() {
        let tiles = TreemapLayout.layout(items, in: container)
        let bounds = container.insetBy(dx: -eps, dy: -eps)
        for tile in tiles {
            #expect(bounds.contains(tile.rect))
        }
        for (index, lhs) in tiles.enumerated() {
            for rhs in tiles[(index + 1)...] {
                let overlap = lhs.rect.insetBy(dx: eps, dy: eps).intersection(rhs.rect.insetBy(dx: eps, dy: eps))
                #expect(overlap.isNull || overlap.isEmpty)
            }
        }
    }

    @Test func hugeItemAmongTinyOnesStaysFiniteAndProportional() throws {
        var many = [TreemapItem(id: "huge", size: 1_000_000_000_000)]
        many += (0 ..< 40).map { TreemapItem(id: "t\($0)", size: 1) }
        let tiles = TreemapLayout.layout(many, in: container)
        #expect(tiles.count == many.count)
        let total = Double(many.reduce(0) { $0 + $1.size })
        for tile in tiles {
            #expect(!tile.rect.isNull && !tile.rect.isInfinite)
            #expect(tile.rect.width.isFinite && tile.rect.height.isFinite)
            let size = try Double(#require(many.first { $0.id == tile.id }?.size))
            let expected = Double(container.width * container.height) * size / total
            #expect(abs(Double(tile.rect.width * tile.rect.height) - expected) < 0.01)
        }
        // Tiny tiles are skipped when drawing; the huge one is not.
        #expect(tiles.first { $0.id == "huge" }?.drawRect() != nil)
        #expect(tiles.filter { $0.id != "huge" }.allSatisfy { $0.drawRect() == nil })
    }

    @Test func drawRectInsetsOrReturnsNil() {
        let big = TreemapTile(id: "a", rect: CGRect(x: 0, y: 0, width: 10, height: 10))
        #expect(big.drawRect() == CGRect(x: 1, y: 1, width: 8, height: 8))
        #expect(TreemapTile(id: "b", rect: CGRect(x: 0, y: 0, width: 1.5, height: 50)).drawRect() == nil)
        #expect(TreemapTile(id: "c", rect: CGRect(x: 0, y: 0, width: 50, height: 0.2)).drawRect() == nil)
    }

    @Test func singleItemFillsContainer() {
        let tiles = TreemapLayout.layout([TreemapItem(id: "only", size: 1)], in: container)
        #expect(tiles.count == 1)
        #expect(tiles[0].rect == container)
    }
}

@MainActor
struct FilesViewStateTests {
    @Test func liveSearchUpdatesResults() {
        let state = FilesViewState()
        let all = state.results.count
        state.criteria.text = "wedding"
        #expect(state.results.count == 1)
        state.criteria.text = "nothing-matches-this"
        #expect(state.results.isEmpty)
        state.criteria.text = ""
        #expect(state.results.count == all)
    }

    @Test func drillDownAndUp() {
        let state = FilesViewState()
        #expect(state.currentNode.id == "root")
        state.drillInto("users")
        state.drillInto("movies")
        #expect(state.breadcrumb.map(\.id) == ["root", "users", "movies"])
        state.drillInto("wedding") // leaf: ignored
        #expect(state.currentNode.id == "movies")
        state.goUp()
        #expect(state.currentNode.id == "users")
        state.jump(toDepth: 0)
        #expect(state.currentNode.id == "root")
        state.goUp() // already at root: safe
        #expect(state.currentNode.id == "root")
    }
}
