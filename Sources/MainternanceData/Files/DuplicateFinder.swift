import CryptoKit
import Darwin
import Foundation
import MainternanceDomain

/// Finds plain files with identical contents in the owner's home folder, in three passes:
///
/// 1. one walk (the shared `FileWalker`, so the same folders are skipped) groups plain files of at least
///    `minimumBytes` by their exact length;
/// 2. files that share a length are compared by the SHA-256 of their first and last 64 KiB;
/// 3. files that still match are compared by the SHA-256 of their whole contents. Only that confirms a group.
///
/// Hard links are one file (the walker reports one name per item, and the finder keeps one file per identity), so
/// two names for the same item are never a pair. Every file is opened without following a link and must still be
/// the same item, with the same length and modified date, as the walk found, before and after it is read; a file
/// that fails any of that, or cannot be read, is dropped, and a group left with fewer than two files is not
/// reported. Files stored only online (iCloud placeholders, `ItemStat.isDataless`) are skipped before anything is
/// opened, because reading one would download it. Read-only. Runs at utility priority and stops when the consuming
/// task is cancelled.
struct DuplicateFinder: DuplicateFinding {
    /// 1 MB, as Finder counts (decimal).
    static let standardMinimum: Int64 = 1_000_000
    /// How much of the start and of the end the second pass compares.
    static let edgeBytes = 65536
    /// The most read from a file at once.
    static let chunkBytes = 65536

    static let walkingPhase = "Looking for files of the same size"

    /// Which reading of a file is about to happen.
    enum Pass: Sendable, Equatable {
        case edges
        case whole
    }

    struct Outcome: Sendable, Equatable {
        let unreadableFolders: Int
        let wasCancelled: Bool
    }

    /// A plain file the walk found, as it was then.
    private struct Candidate {
        let path: String
        let stat: ItemStat
    }

    let walker: FileWalker
    /// Never below one byte: empty files are never duplicates worth showing.
    let minimumBytes: Int64
    /// Told before each file is opened (tests change files at that moment).
    let willRead: @Sendable (Pass, String) -> Void
    /// Told after each chunk of a whole read, with the file's path (tests change files mid-read with it).
    let didReadChunk: @Sendable (String) -> Void
    /// Told the outcome of every search, including one whose consumer has gone (tests watch cancellation with it).
    let ended: @Sendable (Outcome) -> Void
    /// Whether a file the walk found is stored only online, from its path and `lstat` reading. Tests replace it,
    /// since a real iCloud placeholder cannot be made in a temp folder.
    let isDataless: @Sendable (String, ItemStat) -> Bool

    init(
        home: URL, isProtected: @escaping @Sendable (String) -> Bool,
        minimumBytes: Int64 = DuplicateFinder.standardMinimum,
        willRead: @escaping @Sendable (Pass, String) -> Void = { _, _ in },
        didReadChunk: @escaping @Sendable (String) -> Void = { _ in },
        ended: @escaping @Sendable (Outcome) -> Void = { _ in },
        isDataless: @escaping @Sendable (String, ItemStat) -> Bool = { $1.isDataless }
    ) {
        walker = FileWalker(home: home, isProtected: isProtected)
        self.minimumBytes = max(minimumBytes, 1)
        self.willRead = willRead
        self.didReadChunk = didReadChunk
        self.ended = ended
        self.isDataless = isDataless
    }

    func find() -> AsyncStream<DuplicateUpdate> {
        // Nothing is dropped: every confirmed group must reach the screen, and there are only a few phases.
        AsyncStream(bufferingPolicy: .unbounded) { continuation in
            let task = Task.detached(priority: .utility) { [self] in
                let outcome = run(
                    shouldStop: { Task.isCancelled },
                    phase: { continuation.yield(.phase($0)) },
                    group: { continuation.yield(.group($0)) }
                )
                ended(outcome)
                continuation.yield(.finished(
                    unreadableFolders: outcome.unreadableFolders, wasCancelled: outcome.wasCancelled
                ))
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// One search, synchronously. `shouldStop` is asked before every item walked, every file read and every chunk;
    /// once it says true the search returns without reporting anything it had not finished. Groups are reported
    /// longest files first; files inside a group are sorted by path.
    func run(shouldStop: () -> Bool, phase: (String) -> Void, group: (DuplicateGroup) -> Void) -> Outcome {
        var stopped = false
        func stop() -> Bool {
            if !stopped, shouldStop() {
                stopped = true
            }
            return stopped
        }
        phase(Self.walkingPhase)
        var unreadable = 0
        var byLength: [Int64: [Candidate]] = [:]
        walker.walk(
            onFile: { file in
                guard !file.isPackageRoot, file.stat.isRegular, file.stat.size >= minimumBytes,
                      !isDataless(file.path, file.stat) else { return }
                byLength[file.stat.size, default: []].append(Candidate(path: file.path, stat: file.stat))
            },
            onFolderUnreadable: { unreadable += 1 },
            shouldStop: stop
        )
        let lengths = byLength.compactMap { length, files in
            Self.oneNamePerItem(files).count > 1 ? length : nil
        }.sorted(by: >)
        if !stop(), !lengths.isEmpty {
            let count = lengths.reduce(0) { $0 + Self.oneNamePerItem(byLength[$1] ?? []).count }
            phase("Comparing \(count) files that have the same size")
        }
        for length in lengths {
            guard !stop() else { break }
            let groups = confirmedGroups(Self.oneNamePerItem(byLength[length] ?? []), length: length, stop: stop)
            byLength[length] = nil
            // A length interrupted part way is not reported: its groups may be missing copies.
            guard !stop() else { break }
            groups.forEach(group)
        }
        return Outcome(unreadableFolders: unreadable, wasCancelled: stopped)
    }

    /// Files of one length, compared by their start and end, then whole; sorted by their first path.
    private func confirmedGroups(_ files: [Candidate], length: Int64, stop: () -> Bool) -> [DuplicateGroup] {
        var groups: [DuplicateGroup] = []
        for sameEdges in matching(files, pass: .edges, stop: stop).values where sameEdges.count > 1 {
            for (digest, same) in matching(sameEdges, pass: .whole, stop: stop) where same.count > 1 {
                let items = same.map { FileItem(
                    path: $0.path, bytes: $0.stat.allocated, modified: $0.stat.modified, identity: $0.stat.identity
                ) }
                groups.append(DuplicateGroup(
                    id: "\(length)-\(digest)", bytesEach: same.map(\.stat.allocated).min() ?? 0, files: items
                ))
            }
        }
        return groups.sorted { ($0.files.first?.id ?? "") < ($1.files.first?.id ?? "") }
    }

    /// The files by their digest for `pass`; files that could not be read as found are left out. Each file is
    /// opened once.
    private func matching(_ files: [Candidate], pass: Pass, stop: () -> Bool) -> [String: [Candidate]] {
        var byDigest: [String: [Candidate]] = [:]
        for file in files {
            guard !stop() else { break }
            willRead(pass, file.path)
            if let digest = digest(of: file, pass: pass, stop: stop) {
                byDigest[digest, default: []].append(file)
            }
        }
        return byDigest
    }

    /// One file for each item (device and inode): hard links never pair with each other. Sorted by path, so the
    /// first name found is the one kept, and results come out the same every time.
    private static func oneNamePerItem(_ files: [Candidate]) -> [Candidate] {
        var seen = Set<CleanupEntry.Identity>()
        return files.sorted { $0.path < $1.path }.filter { seen.insert($0.stat.identity).inserted }
    }

    // MARK: - Reading

    /// The SHA-256 (hex) of the file's start and end, or of all of it; nil when it cannot be read in full or is no
    /// longer the file the walk found.
    private func digest(of file: Candidate, pass: Pass, stop: () -> Bool) -> String? {
        // O_NOFOLLOW: a file swapped for a link is refused, never followed to whatever it points at.
        let descriptor = open(file.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { return nil }
        // The descriptor is closed here, after the last check on it, never by the handle (an optimized build may
        // release the handle as soon as its last read is done).
        defer { close(descriptor) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        guard Self.isUnchanged(descriptor, from: file.stat) else { return nil }
        var hasher = SHA256()
        let complete = switch pass {
        case .edges:
            Self.readEdges(handle, length: file.stat.size, into: &hasher)
        case .whole:
            readWhole(handle, path: file.path, length: file.stat.size, into: &hasher, stop: stop)
        }
        guard complete, Self.isUnchanged(descriptor, from: file.stat) else { return nil }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// The open file is still the plain file the walk found: same item, length and modified date.
    private static func isUnchanged(_ descriptor: Int32, from found: ItemStat) -> Bool {
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { return false }
        let now = ItemStat(info)
        // A file that became stored only online since the walk is not read: reading would download it.
        return now.isRegular && !now.isDataless && now.identity == found.identity && now.size == found.size
            && now.modified == found.modified
    }

    /// The first `edgeBytes` and the last `edgeBytes` (they overlap for a short file).
    private static func readEdges(_ handle: FileHandle, length: Int64, into hasher: inout SHA256) -> Bool {
        let edge = Int64(edgeBytes)
        guard let head = try? handle.read(upToCount: edgeBytes), Int64(head.count) == min(edge, length) else {
            return false
        }
        hasher.update(data: head)
        guard length > edge else { return true }
        let tailStart = length - edge
        guard (try? handle.seek(toOffset: UInt64(tailStart))) != nil,
              let tail = try? handle.read(upToCount: edgeBytes), tail.count == edgeBytes else { return false }
        hasher.update(data: tail)
        return true
    }

    /// Everything, `chunkBytes` at a time, asking `stop` between chunks. False when stopped or short.
    private func readWhole(
        _ handle: FileHandle, path: String, length: Int64, into hasher: inout SHA256, stop: () -> Bool
    ) -> Bool {
        var total: Int64 = 0
        while total < length {
            guard !stop() else { return false }
            // Each chunk is freed before the next is read, so memory per file stays one chunk.
            let read: Int? = autoreleasepool {
                guard let chunk = try? handle.read(upToCount: Self.chunkBytes), !chunk.isEmpty else { return nil }
                hasher.update(data: chunk)
                return chunk.count
            }
            guard let read else { return false }
            total += Int64(read)
            didReadChunk(path)
        }
        return total == length
    }
}
