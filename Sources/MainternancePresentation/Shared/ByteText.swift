import Foundation
import MainternanceDomain
import Synchronization

/// One formatter shared by every call; the lock keeps access safe under Swift 6.
private let byteFormatter: Mutex<ByteCountFormatter> = {
    let formatter = ByteCountFormatter()
    formatter.countStyle = .decimal
    formatter.allowedUnits = [.useGB, .useMB, .useKB, .useBytes]
    formatter.includesUnit = true
    formatter.allowsNonnumericFormatting = false // Never "Zero KB".
    return Mutex(formatter)
}()

/// The single decimal byte-formatting path (e.g. "41 GB", "240 MB") for the whole app; negatives read as zero.
func formatBytes(_ bytes: Int64) -> String {
    byteFormatter.withLock { $0.string(fromByteCount: max(bytes, 0)) }
}

/// The single rule for the disk reading: nil when the total is unknown (a failed read), never "0 GB".
func diskFreeKnownText(_ snapshot: SystemSnapshot) -> String? {
    snapshot.diskTotalBytes > 0 ? formatBytes(snapshot.diskFreeBytes) : nil
}

/// Free disk space for rows and tiles: `Unavailable` when unknown.
func diskFreeText(_ snapshot: SystemSnapshot) -> String {
    diskFreeKnownText(snapshot) ?? "Unavailable"
}
