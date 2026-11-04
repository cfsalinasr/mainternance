import Foundation
@testable import MainternanceData
import MainternanceDomain

// Helpers for the duplicate finder tests. Files are written only inside a `FilesFixture` temp home.

/// `count` bytes, all non-zero; a different `seed` gives different contents.
func pattern(_ count: Int, seed: Int = 0) -> Data {
    Data((0 ..< count).map { UInt8(truncatingIfNeeded: ($0 &* 7 &+ seed) % 251 + 1) })
}

struct DuplicateRun {
    var groups: [DuplicateGroup] = []
    var outcome = DuplicateFinder.Outcome(unreadableFolders: 0, wasCancelled: false)
}

enum UpdateKind: Equatable {
    case phase
    case group
    case finished(unreadableFolders: Int, wasCancelled: Bool)

    init(_ update: DuplicateUpdate) {
        switch update {
        case .phase:
            self = .phase
        case .group:
            self = .group
        case let .finished(unreadableFolders, wasCancelled):
            self = .finished(unreadableFolders: unreadableFolders, wasCancelled: wasCancelled)
        }
    }
}

extension DuplicateUpdate {
    var group: DuplicateGroup? {
        if case let .group(group) = self {
            return group
        }
        return nil
    }
}

func collectDuplicateUpdates(_ stream: AsyncStream<DuplicateUpdate>) async -> [DuplicateUpdate] {
    var updates: [DuplicateUpdate] = []
    for await update in stream {
        updates.append(update)
    }
    return updates
}

extension FilesFixture {
    @discardableResult
    func write(_ relative: String, _ contents: Data) throws -> URL {
        let url = home.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.write(to: url)
        return url
    }

    func finder(
        minimum: Int64 = 1000, willRead: @escaping @Sendable (DuplicateFinder.Pass, String) -> Void = { _, _ in },
        ended: @escaping @Sendable (DuplicateFinder.Outcome) -> Void = { _ in }
    ) -> DuplicateFinder {
        DuplicateFinder(
            home: home, isProtected: { _ in false }, minimumBytes: minimum, willRead: willRead, ended: ended
        )
    }

    func findDuplicates(
        minimum: Int64 = 1000, willRead: @escaping @Sendable (DuplicateFinder.Pass, String) -> Void = { _, _ in }
    ) -> DuplicateRun {
        var run = DuplicateRun()
        run.outcome = finder(minimum: minimum, willRead: willRead).run(
            shouldStop: { false }, phase: { _ in }, group: { run.groups.append($0) }
        )
        return run
    }
}
