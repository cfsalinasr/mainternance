import Foundation
@testable import MainternanceData
import MainternanceDomain

/// A temp "home" and a temp "Applications" folder. Never the real `~/Library`, `/Applications` or Trash.
struct UninstallerFixture {
    let temp: TempDirectory

    init() throws {
        temp = try TempDirectory()
        for folder in [applications, library] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
    }

    var home: URL {
        temp.url.appendingPathComponent("home", isDirectory: true)
    }

    var library: URL {
        home.appendingPathComponent("Library", isDirectory: true)
    }

    var applications: URL {
        temp.url.appendingPathComponent("Applications", isDirectory: true)
    }

    var lister: AppLister {
        AppLister(applicationFolders: [applications], ownBundlePath: nil)
    }

    var finder: LeftoverFinder {
        LeftoverFinder(home: home)
    }

    /// A `.app` folder with a real `Info.plist` holding `plist`; nil `plist` writes none. Returns its path.
    @discardableResult
    func app(
        _ folderName: String, in parent: URL? = nil, plist: [String: Any]? = [:], bytes: Int = 0
    ) throws -> URL {
        let url = (parent ?? applications).appendingPathComponent(folderName, isDirectory: true)
        let contents = url.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        if let plist {
            try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
                .write(to: contents.appendingPathComponent("Info.plist"))
        }
        if bytes > 0 {
            try payload(bytes).write(to: contents.appendingPathComponent("payload.bin"))
        }
        return url
    }

    func installed(
        _ folderName: String = "Example.app", id: String? = "com.example.app", name: String? = nil
    ) async throws -> InstalledApp {
        var plist: [String: Any] = [:]
        if let id {
            plist["CFBundleIdentifier"] = id
        }
        if let name {
            plist["CFBundleName"] = name
        }
        let url = try app(folderName, plist: plist)
        guard let found = await listed().first(where: { $0.id == url.path }) else {
            throw FixtureError.notListed
        }
        return found
    }

    func listed() async -> [InstalledApp] {
        await lister.listApps()
    }

    /// A folder or file inside `~/Library/<path>`; with `bytes`, a file of that size at the last component.
    @discardableResult
    func library(_ path: String, bytes: Int? = nil) throws -> URL {
        let url = library.appendingPathComponent(path)
        if let bytes {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try payload(bytes).write(to: url)
        } else {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        return url
    }

    func payload(_ bytes: Int) -> Data {
        Data((0 ..< bytes).map { UInt8(truncatingIfNeeded: $0 % 251 + 1) })
    }

    @discardableResult
    func link(_ url: URL, to destination: String) throws -> URL {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(atPath: url.path, withDestinationPath: destination)
        return url
    }
}

enum FixtureError: Error {
    case notListed
}
