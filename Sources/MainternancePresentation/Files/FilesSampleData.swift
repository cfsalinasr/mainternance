import Foundation

// Sample duplicates for the hidden Duplicates tab; Task 6 of the file-explorer plan deletes this file.

enum SampleFileKind: String, CaseIterable, Sendable, Identifiable {
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
    var kind: SampleFileKind
}

struct SampleDuplicateGroup: Identifiable, Equatable, Sendable {
    var id: String
    var files: [SampleFile]
}

enum FilesSampleData {
    private static let day: TimeInterval = 86400
    private static func ago(_ days: Double) -> Date {
        Date(timeIntervalSinceNow: -days * day)
    }

    private static func file(
        _ path: String, _ megabytes: Double, _ days: Double, _ kind: SampleFileKind
    ) -> SampleFile {
        SampleFile(
            name: (path as NSString).lastPathComponent, path: path,
            size: Int64(megabytes * 1_000_000), modified: ago(days), kind: kind
        )
    }

    static let duplicates: [SampleDuplicateGroup] = [
        SampleDuplicateGroup(id: "report", files: [
            file("/Users/me/Documents/Quarterly Report.pdf", 4.2, 3, .document),
            file("/Users/me/Downloads/Quarterly Report (1).pdf", 4.2, 20, .document),
            file("/Users/me/Documents/Archive/Old/Deeply/Nested/Quarterly Report.pdf", 4.2, 300, .document)
        ]),
        SampleDuplicateGroup(id: "photo", files: [
            file("/Users/me/Pictures/Holiday/IMG_0042.heic", 3.4, 40, .image),
            file("/Users/me/Desktop/IMG_0042 copy.heic", 3.4, 39, .image)
        ]),
        SampleDuplicateGroup(id: "installer", files: [
            file("/Users/me/Downloads/installer.dmg", 1900, 12, .archive),
            file("/Users/me/Downloads/installer 2.dmg", 1900, 11, .archive)
        ])
    ]
}
