import Foundation

// Replaced by Domain providers in the file-explorer plan

enum FileKind: String, CaseIterable, Sendable, Identifiable {
    case document, image, video, audio, archive, code, other

    var id: String {
        rawValue
    }

    var title: String {
        switch self {
        case .document: "Documents"
        case .image: "Images"
        case .video: "Videos"
        case .audio: "Audio"
        case .archive: "Archives"
        case .code: "Code"
        case .other: "Other"
        }
    }

    var symbol: String {
        switch self {
        case .document: "doc.text"
        case .image: "photo"
        case .video: "film"
        case .audio: "waveform"
        case .archive: "archivebox"
        case .code: "chevron.left.forwardslash.chevron.right"
        case .other: "doc"
        }
    }
}

struct SampleFile: Identifiable, Equatable, Sendable {
    var id: String {
        path
    }

    var name: String
    var path: String
    var size: Int64
    var modified: Date
    var kind: FileKind
}

struct DuplicateGroup: Identifiable, Equatable, Sendable {
    var id: String
    var files: [SampleFile]
}

struct TreemapNode: Identifiable, Equatable, Sendable {
    var id: String
    var name: String
    /// Leaf size; ignored when `children` is non-empty.
    var leafSize: Int64
    var children: [TreemapNode] = []

    var size: Int64 {
        children.isEmpty ? max(leafSize, 0) : children.reduce(0) { $0 + $1.size }
    }
}

enum FilesSampleData {
    private static let day: TimeInterval = 86400
    private static func ago(_ days: Double) -> Date {
        Date(timeIntervalSinceNow: -days * day)
    }

    private static func file(_ path: String, _ megabytes: Double, _ days: Double, _ kind: FileKind) -> SampleFile {
        SampleFile(
            name: (path as NSString).lastPathComponent, path: path,
            size: Int64(megabytes * 1_000_000), modified: ago(days), kind: kind
        )
    }

    static let files: [SampleFile] = [
        file("/Users/me/Documents/Quarterly Report.pdf", 4.2, 3, .document),
        file("/Users/me/Documents/Taxes/2025 Return.pdf", 2.1, 200, .document),
        file("/Users/me/Pictures/Holiday/IMG_0042.heic", 3.4, 40, .image),
        file("/Users/me/Pictures/Holiday/IMG_0043.heic", 3.6, 40, .image),
        file("/Users/me/Movies/Wedding.mov", 4800, 400, .video),
        file("/Users/me/Movies/Screen Recording.mov", 1250, 5, .video),
        file("/Users/me/Music/Album/Track 01.m4a", 9.8, 900, .audio),
        file("/Users/me/Downloads/installer.dmg", 1900, 12, .archive),
        file("/Users/me/Downloads/backup-2025.zip", 760, 90, .archive),
        file("/Users/me/Developer/mainternance/Package.swift", 0.002, 1, .code),
        file("/Users/me/Developer/mainternance/Sources/App/main.swift", 0.004, 0.2, .code),
        file("/Users/me/Library/Caches/com.example.app/cache.db", 310, 2, .other),
        file("/Users/me/Desktop/notes.txt", 0.01, 0.5, .document),
        file("/Users/me/Desktop/empty.txt", 0, 6, .document),
        file(
            "/Users/me/Documents/Archive/Old/Deeply/Nested/Folder/Structure/For/Testing/Long/Paths/Report Final.pdf",
            4.2,
            700,
            .document
        )
    ]

    static let duplicates: [DuplicateGroup] = [
        DuplicateGroup(id: "report", files: [
            file("/Users/me/Documents/Quarterly Report.pdf", 4.2, 3, .document),
            file("/Users/me/Downloads/Quarterly Report (1).pdf", 4.2, 20, .document),
            file("/Users/me/Documents/Archive/Old/Deeply/Nested/Quarterly Report.pdf", 4.2, 300, .document)
        ]),
        DuplicateGroup(id: "photo", files: [
            file("/Users/me/Pictures/Holiday/IMG_0042.heic", 3.4, 40, .image),
            file("/Users/me/Desktop/IMG_0042 copy.heic", 3.4, 39, .image)
        ]),
        DuplicateGroup(id: "installer", files: [
            file("/Users/me/Downloads/installer.dmg", 1900, 12, .archive),
            file("/Users/me/Downloads/installer 2.dmg", 1900, 11, .archive)
        ])
    ]

    static let largest: [SampleFile] = files.sorted { $0.size > $1.size }

    static let treemap = TreemapNode(id: "root", name: "Macintosh HD", leafSize: 0, children: [
        TreemapNode(id: "users", name: "Users", leafSize: 0, children: [
            TreemapNode(id: "movies", name: "Movies", leafSize: 0, children: [
                TreemapNode(id: "wedding", name: "Wedding.mov", leafSize: 4_800_000_000),
                TreemapNode(id: "rec", name: "Screen Recording.mov", leafSize: 1_250_000_000)
            ]),
            TreemapNode(id: "downloads", name: "Downloads", leafSize: 0, children: [
                TreemapNode(id: "dmg", name: "installer.dmg", leafSize: 1_900_000_000),
                TreemapNode(id: "zip", name: "backup-2025.zip", leafSize: 760_000_000)
            ]),
            TreemapNode(id: "pictures", name: "Pictures", leafSize: 2_400_000_000),
            TreemapNode(id: "documents", name: "Documents", leafSize: 900_000_000),
            TreemapNode(id: "emptydir", name: "Empty", leafSize: 0)
        ]),
        TreemapNode(id: "apps", name: "Applications", leafSize: 14_000_000_000),
        TreemapNode(id: "system", name: "System", leafSize: 22_000_000_000),
        TreemapNode(id: "library", name: "Library", leafSize: 6_500_000_000)
    ])
}
