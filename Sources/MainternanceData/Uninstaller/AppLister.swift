import Foundation
import MainternanceDomain

/// Lists the apps in the Applications folders: direct children that are real `.app` folders (a link, or a file named
/// `.app`, is skipped). Read-only; no sizes are measured, so the list stays fast.
///
/// Not listed: macOS's own apps (identifier starting `com.apple.`) and the running Mainternance bundle. The name,
/// identifier and version come from `Contents/Info.plist`, read with `PropertyListSerialization` from a regular file
/// of at most 1 MiB (never `Bundle(path:)`, which can follow links). An unreadable plist gives an app with its
/// folder name and no identifier.
struct AppLister: AppListing {
    static let maximumPlistBytes = 1_048_576
    static let maximumIdentifierLength = 200

    let applicationFolders: [URL]
    /// The running Mainternance bundle (its folder), which is never offered for removal.
    let ownBundlePath: String?

    init(applicationFolders: [URL], ownBundlePath: String? = Bundle.main.bundlePath) {
        self.applicationFolders = applicationFolders
        self.ownBundlePath = ownBundlePath
    }

    func listApps() async -> [InstalledApp] {
        var apps: [InstalledApp] = []
        var seen = Set<String>()
        for folder in applicationFolders {
            guard !Task.isCancelled else { break }
            let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
            for name in names where name.hasSuffix(".app") {
                let path = (folder.path as NSString).appendingPathComponent(name)
                guard seen.insert(path).inserted, let app = Self.app(at: path) else { continue }
                if Self.isOwnBundle(path, ownBundlePath) || app.bundleID?.hasPrefix("com.apple.") == true {
                    continue
                }
                apps.append(app)
            }
        }
        return apps.sorted { lhs, rhs in
            let order = lhs.name.caseInsensitiveCompare(rhs.name)
            return order == .orderedSame ? lhs.id < rhs.id : order == .orderedAscending
        }
    }

    /// Letters, digits, `.`, `-` and `_`, 1 to 200 characters; anything else is "no identifier" so a hostile plist
    /// can never build a path with `/` or `..`. A text of only dots is refused too (`.`, `..`).
    static func validIdentifier(_ text: String?) -> String? {
        guard let text, !text.isEmpty, text.utf8.count <= maximumIdentifierLength,
              text.unicodeScalars.allSatisfy({ allowed.contains($0) }),
              text.contains(where: { $0 != "." }) else { return nil }
        return text
    }

    private static let allowed: Set<Unicode.Scalar> = Set(
        "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-_".unicodeScalars
    )

    private static func isOwnBundle(_ path: String, _ own: String?) -> Bool {
        guard let own else { return false }
        if path == own {
            return true
        }
        guard let lhs = CleanupRules.resolve(path), let rhs = CleanupRules.resolve(own) else { return false }
        return lhs == rhs
    }

    /// The app at `path`, or nil when it is not a real folder.
    private static func app(at path: String) -> InstalledApp? {
        guard case let .found(info) = ItemStat.read(path), info.type == .directory else { return nil }
        let fallback = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        let plist = readPlist(in: path)
        let given = (plist?["CFBundleDisplayName"] as? String) ?? (plist?["CFBundleName"] as? String)
        let name = given.flatMap { DisplayText.clean($0).isEmpty ? nil : $0 } ?? fallback
        let version = (plist?["CFBundleShortVersionString"] as? String).flatMap {
            $0.isEmpty || $0.utf8.count > 100 ? nil : $0
        }
        return InstalledApp(
            path: path, name: name, bundleID: validIdentifier(plist?["CFBundleIdentifier"] as? String),
            version: version, identity: info.identity
        )
    }

    private static func readPlist(in app: String) -> [String: Any]? {
        let contents = (app as NSString).appendingPathComponent("Contents")
        guard case let .found(folder) = ItemStat.read(contents), folder.type == .directory else { return nil }
        let path = (contents as NSString).appendingPathComponent("Info.plist")
        guard case let .found(file) = ItemStat.read(path), file.isRegular else { return nil }
        let descriptor = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { return nil }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        guard let data = try? handle.read(upToCount: maximumPlistBytes + 1), data.count <= maximumPlistBytes else {
            return nil
        }
        return (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil))
            as? [String: Any]
    }
}
