import Foundation
import MainternanceDomain

/// The Cleanup pieces for the whole app: one measurer and one mover over the same fixed folders.
public struct CleanupServices: Sendable {
    public let scanner: any CleanupScanning
    public let mover: any CleanupMoving

    /// `home` is the owner's home folder; tests pass a temp folder, a fixed `now` and a `trash` that moves items
    /// into a temp folder, so no test touches the real `~/Library`, `~/Downloads` or Trash.
    public init(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        now: @escaping @Sendable () -> Date = Date.init,
        trash: @escaping @Sendable (URL) throws -> Void = CleanupServices.moveToTrash
    ) {
        let rules = CleanupRules(roots: CleanupRoots.standard(home: home), now: now)
        scanner = CleanupMeasurer(rules: rules)
        mover = CleanupMover(rules: rules, trash: trash, isProtected: { ProtectedPaths.isProtected($0) })
    }

    /// The real move: to the owner's Trash, where Finder's Put Back can restore it. A link moves as the link.
    public static func moveToTrash(_ url: URL) throws {
        try FileManager.default.trashItem(at: url, resultingItemURL: nil)
    }
}
