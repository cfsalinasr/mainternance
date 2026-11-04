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
    /// `~/Library` or Trash.
    public init(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        runQuery: @escaping @Sendable (NSPredicate, URL, Int) async -> SpotlightAnswer = FilesServices.runSpotlight,
        trash: @escaping @Sendable (URL) throws -> Void = CleanupServices.moveToTrash,
        isProtected: @escaping @Sendable (String) -> Bool = { ProtectedPaths.isProtected($0) }
    ) {
        search = SpotlightSearcher(home: home, runQuery: runQuery)
        disk = LargeFileScanner(walker: FileWalker(home: home, isProtected: isProtected))
        duplicates = DuplicateFinder(home: home, isProtected: isProtected)
        trasher = FileTrasher(home: home, trash: trash, isProtected: isProtected)
    }

    /// The real Spotlight query (`SpotlightSearcher.runSpotlight`); never called by automated tests.
    @Sendable
    public static func runSpotlight(_ predicate: NSPredicate, _ home: URL, _ limit: Int) async -> SpotlightAnswer {
        await SpotlightSearcher.runSpotlight(predicate, home, limit)
    }
}
