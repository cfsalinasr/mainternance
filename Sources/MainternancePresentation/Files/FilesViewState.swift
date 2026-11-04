import Foundation
import MainternanceDomain
import Observation

enum FilesSegment: String, CaseIterable, Identifiable, Sendable {
    case search, duplicates, large

    /// The tabs the picker offers. Duplicates stays hidden until its real engine is wired in (Task 6).
    static let shown: [FilesSegment] = [.search, .large]

    var id: String {
        rawValue
    }

    var title: String {
        switch self {
        case .search: "Search"
        case .duplicates: "Duplicates"
        case .large: "Large files"
        }
    }
}

/// The real Files screen: Spotlight search, the large-files list and the disk treemap.
///
/// Search waits 300 ms after the last change and only the newest query's answer is shown; criteria with nothing set
/// clear the results without asking. The disk scan runs when the owner presses Scan and the first time the Large files
/// tab opens (never at launch); a cancelled scan keeps the previous result. Leaving the screen calls `cancelWork()`.
@MainActor
@Observable
public final class FilesViewState {
    var segment: FilesSegment = .search
    var criteria = FileSearchCriteria()
    var keepRule: KeepRule = .newest
    /// Sample groups for the hidden Duplicates tab; Task 6 replaces them with the real finder.
    let duplicates: [SampleDuplicateGroup] = FilesSampleData.duplicates

    public private(set) var searchResults: [FileItem] = []
    private(set) var isSearching = false
    private(set) var searchIsTruncated = false
    private(set) var searchIsUnavailable = false
    /// True once an answer for the current criteria is on screen (so "No files found" is not shown before asking).
    private var hasSearched = false

    public private(set) var diskResult: DiskScanResult?
    private(set) var isScanningDisk = false
    private(set) var scanProgress = 0
    /// Ids of the treemap nodes drilled into, outermost first.
    private(set) var drillPath: [String] = []

    @ObservationIgnored private let search: any FileSearching
    @ObservationIgnored private let disk: any DiskScanning
    @ObservationIgnored private let duplicateFinder: any DuplicateFinding
    @ObservationIgnored private let trasher: any FileTrashing
    @ObservationIgnored private let quickLookAction: @MainActor (String) -> Void
    @ObservationIgnored private let revealAction: @MainActor (String) -> Void
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private let sleep: @Sendable (Duration) async throws -> Void
    @ObservationIgnored private var searchGeneration = 0
    @ObservationIgnored private var scanGeneration = 0
    @ObservationIgnored private var scanTask: Task<Void, Never>?

    public init(
        search: any FileSearching,
        disk: any DiskScanning,
        duplicates: any DuplicateFinding,
        trasher: any FileTrashing,
        quickLook: @escaping @MainActor (String) -> Void,
        reveal: @escaping @MainActor (String) -> Void,
        now: @escaping @Sendable () -> Date = { Date() },
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.search = search
        self.disk = disk
        duplicateFinder = duplicates
        self.trasher = trasher
        quickLookAction = quickLook
        revealAction = reveal
        self.now = now
        self.sleep = sleep
    }

    // MARK: - Search

    /// What the search area says instead of a list: Spotlight not answering, or no matches. Nil while there are
    /// results, while asking, or before anything was asked.
    var searchStatusText: String? {
        guard criteria.isActive, hasSearched, !isSearching, searchResults.isEmpty else { return nil }
        return searchIsUnavailable ? FilesText.spotlightUnavailable : FilesText.noMatches
    }

    var searchTruncatedText: String? {
        searchIsTruncated && !searchResults.isEmpty ? FilesText.truncated : nil
    }

    /// Run after every criteria change (the view's `.task(id:)` cancels the previous run). Waits 300 ms, then asks;
    /// only the newest call may change the results.
    func searchChanged() async {
        searchGeneration += 1
        let mine = searchGeneration
        guard criteria.isActive else {
            clearSearch()
            return
        }
        isSearching = true
        do {
            try await sleep(.milliseconds(300))
        } catch {
            if mine == searchGeneration {
                isSearching = false
            }
            return
        }
        guard mine == searchGeneration, !Task.isCancelled else { return }
        let result = await search.search(criteria.query(now: now()))
        guard mine == searchGeneration, !Task.isCancelled else { return }
        searchResults = result.files
        searchIsTruncated = result.isTruncated
        searchIsUnavailable = result.isUnavailable
        hasSearched = true
        isSearching = false
    }

    private func clearSearch() {
        searchResults = []
        searchIsTruncated = false
        searchIsUnavailable = false
        hasSearched = false
        isSearching = false
    }

    // MARK: - Large files and treemap

    var largestFiles: [FileItem] {
        diskResult?.largest ?? []
    }

    var scanProgressText: String? {
        isScanningDisk ? FilesText.scanned(scanProgress) : nil
    }

    var unreadableNote: String? {
        guard let count = diskResult?.unreadableFolders, count > 0 else { return nil }
        return FilesText.unreadable(count)
    }

    /// The size of the whole tree, or of the node on show, as "about" or "at least".
    var totalText: String {
        total(of: diskResult?.tree)
    }

    func total(of node: DiskNode?) -> String {
        FilesText.total(node?.bytes ?? 0, lowerBound: (diskResult?.unreadableFolders ?? 0) > 0)
    }

    /// The chain from the root to the node on show; empty before a scan has finished.
    var breadcrumb: [DiskNode] {
        guard let tree = diskResult?.tree else { return [] }
        var chain = [tree]
        for id in drillPath {
            guard let next = chain.last?.children.first(where: { $0.id == id }), next.isDrillable else { break }
            chain.append(next)
        }
        return chain
    }

    var currentNode: DiskNode {
        breadcrumb.last ?? DiskNode(id: "", name: "", bytes: 0, isOther: false, isPackage: false, children: [])
    }

    /// The current node's folders the owner can open; the one rule for tap, buttons and `drillInto`.
    var drillableChildren: [DiskNode] {
        currentNode.children.filter(\.isDrillable)
    }

    func drillInto(_ id: String) {
        guard let child = currentNode.children.first(where: { $0.id == id }), child.isDrillable else { return }
        drillPath = Array(drillPath.prefix(breadcrumb.count - 1)) + [id]
    }

    func goUp() {
        guard !drillPath.isEmpty else { return }
        drillPath.removeLast()
    }

    func jump(toDepth depth: Int) {
        drillPath = Array(drillPath.prefix(max(depth, 0)))
    }

    /// Starts a scan, unless one is running.
    func startDiskScan() {
        guard !isScanningDisk else { return }
        scanGeneration += 1
        let mine = scanGeneration
        isScanningDisk = true
        scanProgress = 0
        let stream = disk.scan()
        scanTask = Task { [weak self] in
            for await update in stream {
                guard let self, mine == scanGeneration, !Task.isCancelled else { return }
                switch update {
                case let .progress(count):
                    scanProgress = count
                case let .finished(result) where !result.wasCancelled:
                    diskResult = result
                    drillPath = []
                case .finished:
                    break // A stopped walk is only a lower bound: the previous result stays.
                }
            }
            guard let self, mine == scanGeneration else { return }
            isScanningDisk = false
        }
    }

    /// Waits for the running scan to end (tests).
    func waitForScan() async {
        await scanTask?.value
    }

    // MARK: - Lifecycle and actions

    /// The screen (or its tab) appeared: the first time Large files is on screen it scans. Nothing runs on Search.
    public func appear() async {
        if segment == .large, diskResult == nil, !isScanningDisk {
            startDiskScan()
        }
    }

    /// The screen went away: stops the search and the scan; late answers are ignored.
    func cancelWork() {
        searchGeneration += 1
        isSearching = false
        scanGeneration += 1
        scanTask?.cancel()
        isScanningDisk = false
    }

    func quickLook(_ file: FileItem) {
        quickLookAction(file.id)
    }

    func reveal(_ file: FileItem) {
        revealAction(file.id)
    }
}
