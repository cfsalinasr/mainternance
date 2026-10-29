import MainternanceDomain

/// No engine produces suggestions yet.
public struct NoSuggestedActionsProvider: SuggestedActionsProviding {
    public init() {}

    public func suggestedActions() async -> [SuggestedAction] {
        []
    }
}
