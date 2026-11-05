import Foundation
import MainternanceDomain

/// The Files pieces for the whole app: Spotlight search, the disk scan (large files and the disk tree), the
/// duplicate finder and the trasher, all over the same home folder and the same protected-places guard.
public struct FilesServices: Sendable {
    public let search: any FileSearching
    public let disk: any DiskScanning
    public let duplicates: any DuplicateFinding
    public let trasher: any FileTrashing

    /// `home` is the owner's home folder. Tests pass a temp folder, a fake `runQuery` (Spotlight is never queried
    /// from tests) and a `trash` that moves items into a temp folder, so no test touches the real home folder,
    /// `~/Library` or Trash. Without `isProtected`, the protected places are `ProtectedPaths`, with its fixed folders
    /// resolved once here (the walker asks once per folder): the trasher gets `ProtectedPaths.isProtected`, the walks
    /// get only the protected places themselves (a folder that holds the app, such as Downloads, is still walked; the
    /// app inside it is not). A given `isProtected` is used for both.
    public init(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        runQuery: @escaping @Sendable (NSPredicate, URL, Int) async -> SpotlightAnswer = FilesServices.runSpotlight,
        trash: @escaping @Sendable (URL) throws -> Void = CleanupServices.moveToTrash,
        isProtected given: (@Sendable (String) -> Bool)? = nil
    ) {
        let resolved = ProtectedPaths.Resolved()
        let isProtected = given ?? { resolved.isProtected($0) }
        let isWalkProtected = given ?? { resolved.isWithinProtected($0) }
        search = SpotlightSearcher(home: home, runQuery: runQuery)
        disk = LargeFileScanner(walker: FileWalker(home: home, isProtected: isWalkProtected))
        duplicates = DuplicateFinder(home: home, isProtected: isWalkProtected)
        trasher = FileTrasher(home: home, trash: trash, isProtected: isProtected)
    }

    /// `ProtectedPaths.isProtected`, with the fixed folders resolved once.
    static func protectedChecker() -> @Sendable (String) -> Bool {
        let resolved = ProtectedPaths.Resolved()
        return { resolved.isProtected($0) }
    }

    /// The real Spotlight query (`SpotlightSearcher.runSpotlight`); never called by automated tests.
    @Sendable
    public static func runSpotlight(_ predicate: NSPredicate, _ home: URL, _ limit: Int) async -> SpotlightAnswer {
        await SpotlightSearcher.runSpotlight(predicate, home, limit)
    }
}
