import Foundation
import MainternanceDomain
import Testing

@Suite("Cleanup types")
struct CleanupTypesTests {
    private func entry(
        _ name: String, bytes: Int64, lowerBound: Bool = false, type: CleanupEntry.ItemType = .directory
    ) -> CleanupEntry {
        CleanupEntry(
            path: "/Users/me/Library/Caches/\(name)", bytes: bytes, isLowerBound: lowerBound, type: type,
            modified: nil
        )
    }

    @Test("an entry is identified by its path and named after its last component")
    func entryIdentity() {
        let item = entry("com.example.app", bytes: 10)
        #expect(item.id == "/Users/me/Library/Caches/com.example.app")
        #expect(item.name == "com.example.app")
        #expect(item.isDirectory)
        #expect(!entry("a", bytes: 1, type: .file).isDirectory)
        #expect(!entry("b", bytes: 1, type: .symbolicLink).isDirectory)
    }

    @Test("a shown name has no control or bidi characters; the real name stays as read")
    func displayName() {
        let odd = entry("evil\u{202E}gpj.app\nline", bytes: 1)
        #expect(odd.name == "evil\u{202E}gpj.app\nline")
        #expect(odd.displayName == "evilgpj.app line")
        #expect(entry("-leading dash", bytes: 1).displayName == "-leading dash")
    }

    @Test("a category adds up its entries and is a lower bound when any entry is")
    func categoryTotals() {
        let exact = CleanupCategory(kind: .caches, entries: [entry("a", bytes: 100), entry("b", bytes: 50)])
        #expect(exact.id == "caches")
        #expect(exact.bytes == 150)
        #expect(!exact.isLowerBound)
        let partial = CleanupCategory(
            kind: .logs, entries: [entry("a", bytes: 1), entry("b", bytes: 2, lowerBound: true)]
        )
        #expect(partial.isLowerBound)
        #expect(CleanupCategory(kind: .logs, entries: []).bytes == 0)
    }

    @Test("totals never overflow: they stop at the largest value")
    func saturatingTotals() {
        let huge = CleanupCategory(kind: .caches, entries: [entry("a", bytes: .max), entry("b", bytes: 5)])
        #expect(huge.bytes == .max)
        let measurement = CleanupMeasurement(categories: [huge, huge], measuredAt: Date(timeIntervalSince1970: 0))
        #expect(measurement.totalBytes == .max)
    }

    @Test("the measurement total is the sum of its categories")
    func measurementTotal() {
        let measurement = CleanupMeasurement(
            categories: [
                CleanupCategory(kind: .caches, entries: [entry("a", bytes: 100)]),
                CleanupCategory(kind: .logs, entries: [entry("b", bytes: 20)])
            ],
            measuredAt: Date(timeIntervalSince1970: 0), unreadable: [.installers]
        )
        #expect(measurement.totalBytes == 120)
        #expect(!measurement.isLowerBound)
        #expect(measurement.unreadable == [.installers])
    }

    @Test("an outcome counts only what was moved")
    func outcomeCountsMoved() {
        let outcome = CleanupOutcome(
            moved: [entry("a", bytes: 100), entry("b", bytes: 5)],
            failed: [CleanupFailure(entry: entry("c", bytes: 1000), reason: "In use")]
        )
        #expect(outcome.movedBytes == 105)
        #expect(outcome.failed.map(\.reason) == ["In use"])
    }

    @Test("refusals read as plain sentences")
    func refusalText() {
        #expect(CleanupRefusal.notInCleanupFolder.text == "It is not in one of the folders Cleanup looks at.")
        #expect(CleanupRefusal.protected.text == "It is in a protected place.")
        #expect(CleanupRefusal.protectedLink.text == "This is a link to a protected place.")
        #expect(CleanupRefusal.vanished.text == "It is no longer there.")
        #expect(CleanupRefusal.changed.text == "It changed since it was measured.")
        #expect(CleanupRefusal.otherVolume.text == "It is on another disk, so Cleanup leaves it alone.")
        #expect(CleanupRefusal.unreadable.text == "It could not be checked, so it was left where it is.")
        #expect(CleanupRefusal.trashFailed("Busy").text == "macOS could not move it to the Trash: Busy")
    }

    @Test("an entry keeps the disk identity it was measured with, when known")
    func entryDiskIdentity() {
        #expect(entry("a", bytes: 1).identity == nil)
        let known = CleanupEntry(
            path: "/Users/me/Library/Caches/a", bytes: 1, isLowerBound: false, type: .file, modified: nil,
            identity: CleanupEntry.Identity(device: 3, inode: 42)
        )
        #expect(known.identity == CleanupEntry.Identity(device: 3, inode: 42))
    }

    @Test("old installers start unticked; caches, logs and developer caches start ticked")
    func defaultSelection() {
        #expect(!CleanupKind.installers.isSelectedByDefault)
        #expect(CleanupKind.caches.isSelectedByDefault)
        #expect(CleanupKind.logs.isSelectedByDefault)
        #expect(CleanupKind.developer.isSelectedByDefault)
    }
}
