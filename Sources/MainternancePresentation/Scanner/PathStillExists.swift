import Foundation

/// Whether something (a file, a link or a folder) is still at `path`. A symbolic link counts as there: it is
/// looked at, not followed (`lstat`).
@Sendable
public func pathStillExists(_ path: String) -> Bool {
    var info = stat()
    return lstat(path, &info) == 0
}
