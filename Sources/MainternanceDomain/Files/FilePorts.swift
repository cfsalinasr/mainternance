import Foundation

/// Walks the owner's home folder for the large-files list and the disk tree.
public protocol DiskScanning: Sendable {
    /// Progress updates, then one `finished`, then the stream ends. Cancelling the consuming task (or dropping the
    /// stream) stops the walk; the walk then ends with a result marked `wasCancelled`.
    func scan() -> AsyncStream<DiskScanUpdate>
}

/// Finds plain files with identical contents in the owner's home folder.
public protocol DuplicateFinding: Sendable {
    /// Phases and groups as they are confirmed, then one `finished`, then the stream ends. Cancelling the consuming
    /// task (or dropping the stream) stops the search; it then ends with `wasCancelled`.
    func find() -> AsyncStream<DuplicateUpdate>
}

/// Searches the owner's home folder by name, kind, size and date.
public protocol FileSearching: Sendable {
    /// Matching plain files, newest change first, capped. An empty query finds nothing. Cancelling the task gives an
    /// empty result.
    func search(_ query: FileSearchQuery) async -> FileSearchResult
}

/// Moves files the owner chose to the Trash, checking each one again first; never deletes anything.
public protocol FileTrashing: Sendable {
    /// Moves each plain file that is still exactly as it was found; refuses the rest with a reason. One refusal
    /// never stops the others.
    func moveToTrash(_ files: [FileItem]) async -> FileTrashOutcome
    /// Moves the copies in `remove` out of `group`, but only while at least one other copy of the group stays where
    /// it is, unchanged. Otherwise nothing at all is moved.
    func moveDuplicatesToTrash(_ group: DuplicateGroup, remove: [FileItem]) async -> FileTrashOutcome
}
