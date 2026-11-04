import Foundation
import MainternanceDomain
import Testing

@Suite("File trash types")
struct FileTrashTypesTests {
    private static let refusals: [FileRefusal] = [
        .notInHome, .hiddenPlace, .protected, .link, .notPlainFile, .otherVolume, .changed, .vanished, .unreadable,
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
