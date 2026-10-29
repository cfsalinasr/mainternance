import Foundation

struct CleanupCategory: Identifiable, Equatable {
    let id: String
    let name: String
    let detail: String
    let symbol: String
    let bytes: Int64
}

enum StartupKind: CaseIterable, Identifiable {
    case loginItem, launchAgent, launchDaemon

    var id: Self {
        self
    }

    var title: String {
        switch self {
        case .loginItem: "Login items"
        case .launchAgent: "Launch agents"
        case .launchDaemon: "Launch daemons"
        }
    }
}

struct StartupItem: Identifiable, Equatable {
    let id: String
    let name: String
    let detail: String
    let kind: StartupKind
    /// Added since the last review; shown as a `New` text badge.
    let isNew: Bool
    var isEnabled: Bool
}

struct Leftover: Identifiable, Equatable {
    let id: String
    let path: String
    let bytes: Int64
}

struct SampleApp: Identifiable, Equatable {
    let id: String
    let name: String
    let leftovers: [Leftover]

    var totalBytes: Int64 {
        SampleLists.sum(leftovers.map(\.bytes))
    }
}

/// Sample rows for the Cleanup, Startup and Uninstaller screens. Replaced by real engines in later plans.
enum SampleLists {
    private static let gigabyte: Int64 = 1_000_000_000
    private static let megabyte: Int64 = 1_000_000

    /// Totals 12 GB, matching the Home suggested action.
    static let cleanupCategories: [CleanupCategory] = [
        CleanupCategory(
            id: "caches",
            name: "Caches",
            detail: "App and browser caches",
            symbol: "internaldrive",
            bytes: 4 * gigabyte + 200 * megabyte
        ),
        CleanupCategory(
            id: "logs",
            name: "Logs",
            detail: "Diagnostic and crash logs",
            symbol: "doc.text",
            bytes: 900 * megabyte
        ),
        CleanupCategory(
            id: "temp",
            name: "Temp files",
            detail: "Leftover temporary files",
            symbol: "clock.arrow.circlepath",
            bytes: 1 * gigabyte + 300 * megabyte
        ),
        CleanupCategory(
            id: "installers",
            name: "Old installers",
            detail: "Disk images and packages in Downloads",
            symbol: "shippingbox",
            bytes: 3 * gigabyte + 100 * megabyte
        ),
        CleanupCategory(
            id: "xcode",
            name: "Xcode and developer caches",
            detail: "Derived data and simulator caches",
            symbol: "hammer",
            bytes: 2 * gigabyte + 500 * megabyte
        )
    ]

    static let startupItems: [StartupItem] = [
        StartupItem(
            id: "login-notes",
            name: "Menu Notes",
            detail: "Opens at login",
            kind: .loginItem,
            isNew: false,
            isEnabled: true
        ),
        StartupItem(
            id: "login-sync",
            name: "Cloud Sync Helper",
            detail: "Opens at login",
            kind: .loginItem,
            isNew: true,
            isEnabled: true
        ),
        StartupItem(
            id: "agent-updater",
            name: "com.example.updater",
            detail: "~/Library/LaunchAgents",
            kind: .launchAgent,
            isNew: true,
            isEnabled: true
        ),
        StartupItem(
            id: "agent-backup",
            name: "com.example.backup",
            detail: "~/Library/LaunchAgents",
            kind: .launchAgent,
            isNew: false,
            isEnabled: false
        ),
        StartupItem(
            id: "daemon-vpn",
            name: "com.example.vpn.helper",
            detail: "/Library/LaunchDaemons",
            kind: .launchDaemon,
            isNew: true,
            isEnabled: true
        ),
        StartupItem(
            id: "daemon-audio",
            name: "com.example.audio.driver",
            detail: "/Library/LaunchDaemons",
            kind: .launchDaemon,
            isNew: false,
            isEnabled: true
        )
    ]

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

    static var cleanupTotalBytes: Int64 {
        sum(cleanupCategories.map(\.bytes))
    }
}
