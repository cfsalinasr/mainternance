import MainternanceDomain
import SwiftUI

/// Every user-visible string that marks sample (not yet real) content, pinned by tests.
enum SampleDataCopy {
    static let badgeText = "Sample data"
    static let badgeAccessibilityLabel = "Sample data, not your real files"
    static let sidebarMarker = "Sample"
    static let sidebarAccessibilitySuffix = "sample data"
    static let settingsNote = "Not connected yet: these settings are not applied."

    /// Screens whose engines do not exist yet.
    static func isSample(_ destination: AppDestination) -> Bool {
        switch destination {
        case .files, .scanner, .cleanup, .startup, .uninstaller: true
        case .home, .settings: false
        }
    }

    static func sidebarAccessibilityLabel(title: String, destination: AppDestination) -> String {
        isSample(destination) ? "\(title), \(sidebarAccessibilitySuffix)" : title
    }
}

/// Compact capsule shown at the top of the screens that still show sample data.
struct SampleDataBadge: View {
    var body: some View {
        Text(SampleDataCopy.badgeText)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 3)
            .background(.quaternary, in: Capsule())
            .accessibilityLabel(SampleDataCopy.badgeAccessibilityLabel)
    }
}
