import Foundation

/// Lists the installed apps.
public protocol AppListing: Sendable {
    /// Sorted by name, case-insensitive. Sizes are not measured.
    func listApps() async -> [InstalledApp]
}

/// Finds what an app left in the owner's `~/Library`, and measures it.
public protocol LeftoverFinding: Sendable {
    /// Largest leftover first. A cancelled call returns at once with sizes as lower bounds.
    func details(for app: InstalledApp) async -> AppDetails
}

/// Moves an app and the chosen leftovers to the Trash; never deletes anything.
public protocol AppUninstalling: Sendable {
    /// The app first (when `includeApp`); if it is refused or macOS cannot move it, no leftover is tried and all are
    /// reported in `skipped`. With `includeApp` false only the leftovers are moved.
    func moveToTrash(app: InstalledApp, appBytes: Int64, leftovers: [Leftover], includeApp: Bool) async
        -> UninstallOutcome
}
