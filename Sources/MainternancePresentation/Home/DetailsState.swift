/// Whether the Details disclosure has enough history to draw anything.
enum DetailsState: Equatable {
    case collecting
    case ready

    static let collectingText = "Collecting data…"

    /// `.ready` once at least two samples carry any value; empty (all-nil) samples do not count.
    init(history: [OverviewSample]) {
        let withValue = history.filter { $0.cpu != nil || $0.gpu != nil || $0.memoryPressure != nil }
        self = withValue.count >= 2 ? .ready : .collecting
    }
}
