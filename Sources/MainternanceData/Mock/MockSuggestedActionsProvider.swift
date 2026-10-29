import Foundation
import MainternanceDomain

public struct MockSuggestedActionsProvider: SuggestedActionsProviding {
    public init() {}

    public func suggestedActions() async -> [SuggestedAction] {
        [
            SuggestedAction(
                id: "cleanup", title: "Clear 12 GB of junk", detail: "Caches, logs, old installers",
                symbol: "sparkles", destination: .cleanup
            ),
            SuggestedAction(
                id: "startup", title: "Review 3 new login items", detail: "Added since last week",
                symbol: "power", destination: .startup
            ),
            SuggestedAction(
                id: "duplicates", title: "4 GB of duplicates found", detail: "Review before removing",
                symbol: "doc.on.doc", destination: .files
            )
        ]
    }
}
