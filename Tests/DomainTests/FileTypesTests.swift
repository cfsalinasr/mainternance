import Foundation
import MainternanceDomain
import Testing

@Suite("File types")
struct FileTypesTests {
    @Test("kinds come from the extension, ignoring case; anything unknown is other")
    func kindsByExtension() {
        #expect(FileKind.kind(forExtension: "pdf") == .document)
        #expect(FileKind.kind(forExtension: "PDF") == .document)
        #expect(FileKind.kind(forExtension: "JpEg") == .image)
        #expect(FileKind.kind(forExtension: "heic") == .image)
        #expect(FileKind.kind(forExtension: "mov") == .video)
        #expect(FileKind.kind(forExtension: "MP4") == .video)
        #expect(FileKind.kind(forExtension: "mp3") == .audio)
        #expect(FileKind.kind(forExtension: "zip") == .archive)
        #expect(FileKind.kind(forExtension: "dmg") == .archive)
        #expect(FileKind.kind(forExtension: "swift") == .code)
        #expect(FileKind.kind(forExtension: "py") == .code)
        #expect(FileKind.kind(forExtension: "") == .other)
        #expect(FileKind.kind(forExtension: "unknownext") == .other)
        #expect(FileKind.allCases.count == 7)
    }

    @Test("a file is identified by its path, named after its last component, its kind from its extension")
    func fileItem() {
        let modified = Date(timeIntervalSince1970: 1_700_000_000)
        let identity = CleanupEntry.Identity(device: 1, inode: 42)
        let item = FileItem(path: "/Users/me/Movies/Trip.MOV", bytes: 123, modified: modified, identity: identity)
        #expect(item.id == "/Users/me/Movies/Trip.MOV")
        #expect(item.name == "Trip.MOV")
        #expect(item.bytes == 123)
        #expect(item.modified == modified)
        #expect(item.kind == .video)
        #expect(item.identity == identity)
        #expect(FileItem(path: "/a/b", bytes: -5, modified: modified, identity: nil).bytes == 0)
    }

    @Test("odd names display safely; the real path stays as read")
    func oddNames() {
        let path = "/Users/me/-rf evil\u{202E}gpj.exe\nline"
        let item = FileItem(path: path, bytes: 1, modified: Date(), identity: nil)
        #expect(item.id == path)
        #expect(item.name == "-rf evil\u{202E}gpj.exe\nline")
        #expect(item.displayName == "-rf evilgpj.exe line")
        #expect(item.displayPath == "/Users/me/-rf evilgpj.exe line")
    }

    @Test("only a plain folder with children can be drilled into")
    func drillable() {
        let file = DiskNode(id: "/h/a", name: "a", bytes: 10, isOther: false, isPackage: false, children: [])
        let folder = DiskNode(id: "/h", name: "h", bytes: 10, isOther: false, isPackage: false, children: [file])
        let package = DiskNode(id: "/h/X.app", name: "X.app", bytes: 10, isOther: false, isPackage: true, children: [])
        let other = DiskNode(
            id: "/h\u{0}other",
            name: "Other",
            bytes: 10,
            isOther: true,
            isPackage: false,
            children: []
        )
        #expect(folder.isDrillable)
        #expect(!file.isDrillable)
        #expect(!package.isDrillable)
        #expect(!other.isDrillable)
        #expect(folder.displayName == "h")
    }

    @Test("trees compare by content")
    func treeEquality() {
        func tree(_ bytes: Int64) -> DiskNode {
            let leaf = DiskNode(id: "/h/a", name: "a", bytes: bytes, isOther: false, isPackage: false, children: [])
            return DiskNode(id: "/h", name: "h", bytes: bytes, isOther: false, isPackage: false, children: [leaf])
        }
        #expect(tree(5) == tree(5))
        #expect(tree(5) != tree(6))
    }
}
