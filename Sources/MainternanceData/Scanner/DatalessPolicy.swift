import Darwin
import Synchronization

/// Keeps a child process (clamscan) from making iCloud download files that are stored only online ("dataless"
/// files, for example evicted Desktop and Documents files with "Optimize Mac Storage").
///
/// A new process inherits the materialization policy of the app at the moment it starts
/// (`setiopolicy_np(3)`: "New processes inherit the policy of their parent process"). So the app's PROCESS policy is
/// turned off just around the start of the child and put back right after, which leaves the rest of the app as it
/// was. Best effort: a test can pin that the policy is off while the child is started, not that macOS honours it in
/// the child. A dataless file the child cannot open is reported by clamscan as a file it could not open, so it is
/// counted as not scanned.
enum DatalessPolicy {
    /// The two system calls, replaceable in tests. Both return -1 on failure, like the real ones.
    struct System: Sendable {
        let get: @Sendable () -> Int32
        let set: @Sendable (Int32) -> Int32

        static let live = System(
            get: { getiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_PROCESS) },
            set: { setiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_PROCESS, $0) }
        )
    }

    /// Serializes every change of the process-wide policy, so two starts never undo each other's setting.
    private static let lock = Mutex(())

    /// The app's current process policy, read under the same lock as changes (tests only need a stable value).
    static func currentProcessPolicy() -> Int32 {
        lock.withLock { _ in System.live.get() }
    }

    /// Runs `body` (which must start the child synchronously) with materialization OFF for this process, then puts
    /// the earlier policy back. When the earlier policy cannot be read the default is put back; when OFF cannot be
    /// set, `body` still runs (the scan is not refused) and nothing is undone. `body` must not call back into this.
    static func withMaterializationOff<T>(_ system: System = .live, _ body: () -> T) -> T {
        lock.withLock { _ in
            let earlier = system.get()
            let changed = system.set(IOPOL_MATERIALIZE_DATALESS_FILES_OFF) == 0
            let result = body()
            if changed {
                _ = system.set(earlier >= 0 ? earlier : IOPOL_MATERIALIZE_DATALESS_FILES_DEFAULT)
            }
            return result
        }
    }
}
