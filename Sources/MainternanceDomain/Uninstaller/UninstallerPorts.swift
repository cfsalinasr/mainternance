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
