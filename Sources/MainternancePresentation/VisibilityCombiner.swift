import MainternanceDomain

/// ORs the visibility of several windows (the popover and the main window) into the one flag the
/// `OverviewViewModel` understands, so neither window can hide the model while the other is on screen. Also knows
/// whether Home itself is on screen: the main window is visible and shows Home (the popover has no suggestions).
public struct VisibilityCombiner: Sendable, Equatable {
    public enum Source: Hashable, Sendable {
        case popover, window
    }

    private var visibleSources: Set<Source> = []
    private var selection: AppDestination = .home

    public init() {}

    public var isVisible: Bool {
        !visibleSources.isEmpty
    }

    public var isHomeVisible: Bool {
        visibleSources.contains(.window) && selection == .home
    }

    /// Records which screen the main window shows.
    public mutating func select(_ destination: AppDestination) {
        selection = destination
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

/// Feeds the combined visibility to the view model, and tells `onHomeVisibilityChange` each time Home comes on or
/// goes off screen (before the model refreshes); one instance is shared by every window.
@MainActor
public final class VisibilityCoordinator {
    private var combiner = VisibilityCombiner()
    private var homeVisible = false
    private let apply: @MainActor (Bool) -> Void
    private let onHomeVisibilityChange: @MainActor (Bool) -> Void

    public init(
        viewModel: OverviewViewModel,
        onHomeVisibilityChange: @escaping @MainActor (Bool) -> Void = { _ in
            // Default: nobody needs to know (tests of the model alone).
        }
    ) {
        apply = { viewModel.setVisible($0) }
        self.onHomeVisibilityChange = onHomeVisibilityChange
    }

    public func report(_ source: VisibilityCombiner.Source, visible: Bool) {
        let combined = combiner.update(source, visible: visible)
        tellHome()
        apply(combined)
    }

    /// The main window now shows `destination`.
    public func select(_ destination: AppDestination) {
        combiner.select(destination)
        tellHome()
    }

    private func tellHome() {
        guard combiner.isHomeVisible != homeVisible else { return }
        homeVisible = combiner.isHomeVisible
        onHomeVisibilityChange(homeVisible)
    }
}
