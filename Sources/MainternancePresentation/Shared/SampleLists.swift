import Foundation

struct Leftover: Identifiable, Equatable {
    let id: String
    let path: String
    let bytes: Int64

    /// The last path component ("~/Library/Logs/App" -> "App"); the whole path when it has no component ("/" or "~").
    var displayName: String {
        path.split(separator: "/").last.map(String.init) ?? path
    }
}

struct SampleApp: Identifiable, Equatable {
    let id: String
    let name: String
    let leftovers: [Leftover]

    var totalBytes: Int64 {
        SampleLists.sum(leftovers.map(\.bytes))
    }
}

/// Sample rows for the Uninstaller screen. Replaced by real engines in later plans.
enum SampleLists {
    private static let megabyte: Int64 = 1_000_000

    static let apps: [SampleApp] = [
        SampleApp(id: "photo-studio", name: "Photo Studio", leftovers: [
            Leftover(id: "ps-support", path: "~/Library/Application Support/PhotoStudio", bytes: 820 * megabyte),
            Leftover(id: "ps-cache", path: "~/Library/Caches/com.example.photostudio", bytes: 240 * megabyte),
            Leftover(id: "ps-prefs", path: "~/Library/Preferences/com.example.photostudio.plist", bytes: 12000)
        ]),
        SampleApp(id: "video-editor", name: "Video Editor", leftovers: [
            Leftover(id: "ve-support", path: "~/Library/Application Support/VideoEditor", bytes: 1400 * megabyte),
            Leftover(id: "ve-logs", path: "~/Library/Logs/VideoEditor", bytes: 35 * megabyte)
        ]),
        SampleApp(id: "chat-client", name: "Chat Client", leftovers: [
            Leftover(id: "cc-container", path: "~/Library/Containers/com.example.chat", bytes: 310 * megabyte)
        ])
    ]

    static func sum(_ values: [Int64]) -> Int64 {
        values.reduce(0) { $0 + max($1, 0) }
    }
}
