/// ORs the visibility of several windows (the popover and the main window) into the one flag the
/// `OverviewViewModel` understands, so neither window can hide the model while the other is on screen.
public struct VisibilityCombiner: Sendable, Equatable {
    public enum Source: Hashable, Sendable {
        case popover, window
    }

    private var visibleSources: Set<Source> = []

    public init() {}

    public var isVisible: Bool {
        !visibleSources.isEmpty
    }

    /// Records one source's state and returns the combined visibility.
    @discardableResult
    public mutating func update(_ source: Source, visible: Bool) -> Bool {
        if visible {
            visibleSources.insert(source)
        } else {
            visibleSources.remove(source)
        }
        return isVisible
    }
}

/// Feeds the combined visibility to the view model; one instance is shared by every window.
@MainActor
public final class VisibilityCoordinator {
    private var combiner = VisibilityCombiner()
    private let apply: @MainActor (Bool) -> Void

    public init(viewModel: OverviewViewModel) {
        apply = { viewModel.setVisible($0) }
    }

    public func report(_ source: VisibilityCombiner.Source, visible: Bool) {
        apply(combiner.update(source, visible: visible))
    }
}
