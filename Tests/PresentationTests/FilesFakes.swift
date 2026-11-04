import Foundation
import MainternanceDomain
@testable import MainternancePresentation
import Synchronization

/// A search that answers at once with a scripted result and records every query it was asked.
final class FakeFileSearch: FileSearching {
    private let state = Mutex<(result: FileSearchResult, queries: [FileSearchQuery])>(
        (FileSearchResult(files: [], isTruncated: false), [])
    )

    func script(_ result: FileSearchResult) {
        state.withLock { $0.result = result }
    }

    var queries: [FileSearchQuery] {
        state.withLock { $0.queries }
    }

    func search(_ query: FileSearchQuery) async -> FileSearchResult {
        state.withLock { current in
            current.queries.append(query)
            return current.result
        }
    }
}

/// A search whose answers wait until the test releases them, by position.
final class GatedFileSearch: FileSearching {
    let gate = Gate<FileSearchResult>()
    private let asked = Mutex<[FileSearchQuery]>([])

    var queries: [FileSearchQuery] {
        asked.withLock { $0 }
    }

    func search(_ query: FileSearchQuery) async -> FileSearchResult {
        asked.withLock { $0.append(query) }
        return await gate.wait()
    }
}

/// A disk scanner the test drives by hand: it sends updates through `send`, and records how often it was started and
/// how often a consumer stopped listening.
final class FakeDiskScanner: DiskScanning {
    private struct Inner {
        var continuations: [AsyncStream<DiskScanUpdate>.Continuation] = []
        var terminated = 0
    }

    private let inner = Mutex(Inner())

    var starts: Int {
        inner.withLock { $0.continuations.count }
    }

    var terminated: Int {
        inner.withLock { $0.terminated }
    }

    func scan() -> AsyncStream<DiskScanUpdate> {
        AsyncStream { continuation in
            continuation.onTermination = { [weak self] _ in self?.inner.withLock { $0.terminated += 1 } }
            inner.withLock { $0.continuations.append(continuation) }
        }
    }

    func send(_ update: DiskScanUpdate, scan index: Int = 0) {
        let continuation = inner.withLock { $0.continuations.indices.contains(index) ? $0.continuations[index] : nil }
        continuation?.yield(update)
        if case .finished = update {
            continuation?.finish() // like the real scanner: the stream ends after `finished`
        }
    }

    func finish(scan index: Int = 0) {
        let continuation = inner.withLock { $0.continuations.indices.contains(index) ? $0.continuations[index] : nil }
        continuation?.finish()
    }

    func waitForStarts(_ count: Int) async {
        for _ in 0 ..< 10000 where starts < count {
            await Task.yield()
        }
    }
}

/// A duplicate finder the test drives by hand, like `FakeDiskScanner`.
final class FakeDuplicateFinder: DuplicateFinding {
    private struct Inner {
        var continuations: [AsyncStream<DuplicateUpdate>.Continuation] = []
        var terminated = 0
    }

    private let inner = Mutex(Inner())

    var starts: Int {
        inner.withLock { $0.continuations.count }
    }

    var terminated: Int {
        inner.withLock { $0.terminated }
    }

    func find() -> AsyncStream<DuplicateUpdate> {
        AsyncStream { continuation in
            continuation.onTermination = { [weak self] _ in self?.inner.withLock { $0.terminated += 1 } }
            inner.withLock { $0.continuations.append(continuation) }
        }
    }

    func send(_ update: DuplicateUpdate, scan index: Int = 0) {
        let continuation = inner.withLock { $0.continuations.indices.contains(index) ? $0.continuations[index] : nil }
        continuation?.yield(update)
        if case .finished = update {
            continuation?.finish()
        }
    }

    func waitForStarts(_ count: Int) async {
        for _ in 0 ..< 10000 where starts < count {
            await Task.yield()
        }
    }
}

/// A trasher that records every call and moves everything except the paths in `refusals` (path to reason).
final class FakeTrasher: FileTrashing {
    struct Call: Equatable {
        let group: DuplicateGroup?
        let files: [FileItem]
    }

    private let inner = Mutex<(calls: [Call], refusals: [String: String])>(([], [:]))

    var calls: [Call] {
        inner.withLock { $0.calls }
    }

    func refuse(_ path: String, reason: String) {
        inner.withLock { $0.refusals[path] = reason }
    }

    private func outcome(_ files: [FileItem], group: DuplicateGroup?) -> FileTrashOutcome {
        inner.withLock { current in
            current.calls.append(Call(group: group, files: files))
            let refusals = current.refusals
            return FileTrashOutcome(
                moved: files.filter { refusals[$0.id] == nil },
                failed: files.compactMap { file in refusals[file.id].map { FileFailure(file: file, reason: $0) } }
            )
        }
    }

    func moveToTrash(_ files: [FileItem]) async -> FileTrashOutcome {
        outcome(files, group: nil)
    }

    func moveDuplicatesToTrash(_ group: DuplicateGroup, remove: [FileItem]) async -> FileTrashOutcome {
        outcome(remove, group: group)
    }
}

/// A trasher whose single-file move waits until the test releases it.
final class GatedTrasher: FileTrashing {
    let gate = Gate<FileTrashOutcome>()

    func moveToTrash(_: [FileItem]) async -> FileTrashOutcome {
        await gate.wait()
    }

    func moveDuplicatesToTrash(_: DuplicateGroup, remove _: [FileItem]) async -> FileTrashOutcome {
        await gate.wait()
    }
}

/// Records the paths the Quick Look and Reveal closures were called with.
@MainActor
final class FileOpenRecorder {
    var quickLooked: [String] = []
    var revealed: [String] = []
}

/// The durations the state asked to sleep.
final class SleepLog: Sendable {
    private let log = Mutex<[Duration]>([])

    func record(_ duration: Duration) {
        log.withLock { $0.append(duration) }
    }

    var durations: [Duration] {
        log.withLock { $0 }
    }
}

/// Everything a Files test needs: fakes, a clock held still and a sleep that returns at once (and records itself).
@MainActor
final class FilesRig {
    nonisolated static let now = Date(timeIntervalSince1970: 1_800_000_000)

    let search = FakeFileSearch()
    let disk = FakeDiskScanner()
    let duplicates = FakeDuplicateFinder()
    let trasher = FakeTrasher()
    let recorder = FileOpenRecorder()
    let sleeps = SleepLog()
    let state: FilesViewState

    init(
        sleep: (@Sendable (Duration) async throws -> Void)? = nil,
        search override: (any FileSearching)? = nil,
        trasher trasherOverride: (any FileTrashing)? = nil
    ) {
        let sleeps = sleeps
        let recorder = recorder
        state = FilesViewState(
            search: override ?? search, disk: disk, duplicates: duplicates, trasher: trasherOverride ?? trasher,
            quickLook: { recorder.quickLooked.append($0) }, reveal: { recorder.revealed.append($0) },
            now: { FilesRig.now },
            sleep: sleep ?? { duration in sleeps.record(duration) }
        )
    }

    var sleepDurations: [Duration] {
        sleeps.durations
    }

    static func file(_ path: String, bytes: Int64 = 100, age: TimeInterval = 0) -> FileItem {
        FileItem(path: path, bytes: bytes, modified: now.addingTimeInterval(-age), identity: nil)
    }

    static func group(_ id: String, _ files: [FileItem], bytes: Int64 = 2_000_000) -> DuplicateGroup {
        DuplicateGroup(id: id, bytesEach: bytes, files: files)
    }

    /// Yields until `condition` holds, at most 10 000 times, so a regression fails instead of hanging.
    func until(_ condition: @MainActor () -> Bool) async {
        for _ in 0 ..< 10000 where !condition() {
            await Task.yield()
        }
    }

    /// Runs a duplicate scan that streams `groups` and finishes.
    func scanDuplicates(_ groups: [DuplicateGroup], scan index: Int = 0) async {
        state.startDuplicateScan()
        await duplicates.waitForStarts(index + 1)
        for group in groups {
            duplicates.send(.group(group), scan: index)
        }
        duplicates.send(.finished(unreadableFolders: 0, wasCancelled: false), scan: index)
        await state.waitForDuplicateScan()
    }

    /// A small tree: root with a folder (holding a file), a package, a plain file and an Other node.
    static func tree() -> DiskNode {
        let inner = DiskNode(id: "/h/a/f", name: "f", bytes: 10, isOther: false, isPackage: false, children: [])
        let folder = DiskNode(id: "/h/a", name: "a", bytes: 10, isOther: false, isPackage: false, children: [inner])
        let package = DiskNode(id: "/h/p.app", name: "p.app", bytes: 5, isOther: false, isPackage: true, children: [])
        let leaf = DiskNode(id: "/h/x", name: "x", bytes: 3, isOther: false, isPackage: false, children: [])
        let other = DiskNode(id: "/h\0other", name: "Other", bytes: 1, isOther: true, isPackage: false, children: [])
        return DiskNode(
            id: "/h", name: "h", bytes: 19, isOther: false, isPackage: false,
            children: [folder, package, leaf, other]
        )
    }

    static func result(unreadable: Int = 0, cancelled: Bool = false, files: [FileItem]? = nil) -> DiskScanResult {
        DiskScanResult(
            largest: files ?? [file("/h/a/f", bytes: 60_000_000)], tree: tree(), unreadableFolders: unreadable,
            wasCancelled: cancelled
        )
    }
}
