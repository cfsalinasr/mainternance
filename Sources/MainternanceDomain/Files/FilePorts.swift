import Foundation

/// Walks the owner's home folder for the large-files list and the disk tree.
public protocol DiskScanning: Sendable {
    /// Progress updates, then one `finished`, then the stream ends. Cancelling the consuming task (or dropping the
    /// stream) stops the walk; the walk then ends with a result marked `wasCancelled`.
    func scan() -> AsyncStream<DiskScanUpdate>
}
