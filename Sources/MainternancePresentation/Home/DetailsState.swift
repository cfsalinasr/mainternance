/// Whether the Details disclosure has enough history to draw anything.
enum DetailsState: Equatable {
    case collecting
    case ready

    static let collectingText = "Collecting data…"

    /// `.ready` only when at least one row would be drawn (the same predicate as `HistorySeries`: a series
    /// needs two values of its own), so Details is never shown empty.
    init(history: [OverviewSample]) {
        let series = HistorySeries(history: history)
        let hasRow = series.cpu != nil || series.gpu != nil || series.memory != nil
        self = hasRow ? .ready : .collecting
    }
}
