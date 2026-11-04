import Foundation
import MainternanceDomain
import Testing

@Suite("File trash types")
struct FileTrashTypesTests {
    private static let refusals: [FileRefusal] = [
        .notInHome, .hiddenPlace, .protected, .link, .notPlainFile, .insidePackage,
        .otherVolume, .changed, .vanished, .unreadable,
        .trashFailed("The disk is full."), .wouldLeaveNoCopy, .notInGroup, .noKeptCopy
    ]

    @Test("every refusal is a plain, distinct sentence without technical words")
    func refusalTexts() {
        let texts = Self.refusals.map(\.text)
        #expect(Set(texts).count == texts.count)
        for text in texts {
            #expect(text.hasSuffix("."))
            for word in ["inode", "lstat", "symlink", "device", "identity", "volume", "allocated", "nil"] {
                #expect(!text.lowercased().contains(word))
            }
        }
        #expect(FileRefusal.trashFailed("The disk is full.").text.hasSuffix("The disk is full."))
    }

    @Test("duplicate refusals never claim nothing moved, since other files in the same confirm may have")
    func duplicateRefusalTexts() {
        #expect(FileRefusal.noKeptCopy.text
            == "The copy you are keeping is no longer there unchanged, so this one was left where it is.")
        #expect(FileRefusal.wouldLeaveNoCopy.text
            == "That would leave no copy of this file, so this group was left as it is.")
        #expect(FileRefusal.notInGroup.text
            == "One of the files chosen is not a copy in this group, so this group was left as it is.")
    }

    @Test("only moved files count, without overflowing")
    func movedBytes() {
        let small = FileItem(path: "/h/a", bytes: 10, modified: Date(timeIntervalSince1970: 0), identity: nil)
        let huge = FileItem(path: "/h/b", bytes: .max, modified: Date(timeIntervalSince1970: 0), identity: nil)
        let outcome = FileTrashOutcome(moved: [small], failed: [FileFailure(file: huge, reason: "x")])
        #expect(outcome.movedBytes == 10)
        #expect(FileTrashOutcome(moved: [small, huge], failed: []).movedBytes == .max)
        #expect(FileTrashOutcome(moved: [], failed: []).movedBytes == 0)
    }
}
