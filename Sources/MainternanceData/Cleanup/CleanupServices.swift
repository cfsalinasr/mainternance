import Foundation
import MainternanceDomain

/// The Cleanup pieces for the whole app: one measurer and one mover over the same fixed folders.
public struct CleanupServices: Sendable {
    public let scanner: any CleanupScanning
    public let mover: any CleanupMoving
    /// Home's suggestion from the last measurement; the Cleanup screen reports each one through `record`.
    public let estimate: CleanupEstimate

    /// `home` is the owner's home folder; tests pass a temp folder, a fixed `now` and a `trash` that moves items
    /// into a temp folder, so no test touches the real `~/Library`, `~/Downloads` or Trash.
    public init(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        now: @escaping @Sendable () -> Date = Date.init,
        trash: @escaping @Sendable (URL) throws -> Void = SystemTrash.move,
        isLowPowerMode: @escaping @Sendable () -> Bool = { ProcessInfo.processInfo.isLowPowerModeEnabled }
    ) {
        let resolved = ProtectedPaths.Resolved()
        let rules = CleanupRules(
            roots: CleanupRoots.standard(home: home), now: now, holdsApp: { resolved.holdsApp($0) }
        )
        let measurer = CleanupMeasurer(rules: rules)
        scanner = measurer
        estimate = CleanupEstimate(scanner: measurer, now: now, isLowPowerMode: isLowPowerMode)
        mover = CleanupMover(rules: rules, trash: trash, isProtected: { resolved.isProtected($0) })
    }
}
