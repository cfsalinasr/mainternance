import Foundation

public protocol SystemSnapshotProviding: Sendable {
    func currentSnapshot() async -> SystemSnapshot
}

public protocol ScanStatusProviding: Sendable {
    func currentStatus() async -> ScanStatus
}

public protocol SuggestedActionsProviding: Sendable {
    func suggestedActions() async -> [SuggestedAction]
}

public struct SuggestedAction: Sendable, Identifiable, Equatable {
    public var id: String
    public var title: String
    public var detail: String
    public var symbol: String
    public var destination: AppDestination

    public init(id: String, title: String, detail: String, symbol: String, destination: AppDestination) {
        self.id = id
        self.title = title
        self.detail = detail
        self.symbol = symbol
        self.destination = destination
    }
}

public struct Overview: Sendable, Equatable {
    public var snapshot: SystemSnapshot
    public var scan: ScanStatus
    public var report: HealthReport
    public var actions: [SuggestedAction]

    public init(snapshot: SystemSnapshot, scan: ScanStatus, report: HealthReport, actions: [SuggestedAction]) {
        self.snapshot = snapshot
        self.scan = scan
        self.report = report
        self.actions = actions
    }
}

public struct LoadOverview: Sendable {
    private let snapshots: any SystemSnapshotProviding
    private let scans: any ScanStatusProviding
    private let actions: any SuggestedActionsProviding
    private let evaluator: HealthEvaluator
    private let now: @Sendable () -> Date

    public init(
        snapshots: any SystemSnapshotProviding,
        scans: any ScanStatusProviding,
        actions: any SuggestedActionsProviding,
        evaluator: HealthEvaluator = .init(),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.snapshots = snapshots
        self.scans = scans
        self.actions = actions
        self.evaluator = evaluator
        self.now = now
    }

    public func callAsFunction() async -> Overview {
        async let snapshot = snapshots.currentSnapshot()
        async let scan = scans.currentStatus()
        async let suggested = actions.suggestedActions()
        let (s, c, a) = await (snapshot, scan, suggested)
        return Overview(
            snapshot: s, scan: c,
            report: evaluator.evaluate(snapshot: s, scan: c, now: now()),
            actions: a
        )
    }
}
