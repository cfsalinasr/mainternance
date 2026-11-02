import Darwin
import Foundation
import MainternanceDomain

/// The destination folder of a restore, opened once. Every later step of the restore (looking for a free name,
/// creating the partial copy, the final no-overwrite rename, the permission reset) works relative to this open
/// descriptor, so swapping the folder or any folder above it after the check cannot redirect the restore.
struct RestoreFolder {
    let descriptor: Int32
    /// Physical path of the opened folder (`F_GETPATH`), read right after it was opened. This is the path the
    /// protected-path decision was re-checked against.
    let path: String

    /// Opens the physical folder `resolved` (from `realpath`) with `O_DIRECTORY | O_NOFOLLOW`.
    /// `.restoreTargetMissing` when it is gone or not a folder; `.changedSinceScan` when it became a symlink.
    static func open(_ resolved: String) throws -> RestoreFolder {
        let descriptor = Darwin.open(resolved, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else {
            let failure = errno
            // With O_DIRECTORY, macOS reports a symlink as ENOTDIR rather than ELOOP: tell the two apart.
            var info = stat()
            if failure == ELOOP || (lstat(resolved, &info) == 0 && info.st_mode & S_IFMT == S_IFLNK) {
                throw QuarantineError.changedSinceScan
            }
            switch failure {
            case ENOENT, ENOTDIR: throw QuarantineError.restoreTargetMissing
            default: throw QuarantineError.ioFailure(QuarantineFiles.message(failure))
            }
        }
        guard let path = currentPath(of: descriptor) else {
            _ = Darwin.close(descriptor)
            throw QuarantineError.changedSinceScan
        }
        return RestoreFolder(descriptor: descriptor, path: path)
    }

    /// Where the opened folder is right now (it can have been renamed since it was opened).
    func currentPath() -> String? {
        Self.currentPath(of: descriptor)
    }

    private static func currentPath(of descriptor: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        let result = buffer.withUnsafeMutableBytes { fcntl(descriptor, F_GETPATH, $0.baseAddress!) }
        guard result != -1 else { return nil }
        return String(cString: buffer)
    }

    /// The device the opened folder is on (`fstat`), or nil when it cannot be read.
    func device() -> dev_t? {
        var info = stat()
        return fstat(descriptor, &info) == 0 ? info.st_dev : nil
    }

    func close() {
        _ = Darwin.close(descriptor)
    }

    /// `lstat` of the entry `name` in this folder (never follows a symlink); nil when nothing is there.
    func entryInfo(_ name: String) -> stat? {
        var info = stat()
        return fstatat(descriptor, name, &info, AT_SYMLINK_NOFOLLOW) == 0 ? info : nil
    }

    /// Moves the item at the absolute path `source` into this folder as `name`, never overwriting.
    func moveIn(fromPath source: String, as name: String) throws {
        try Self.settle(renameatx_np(AT_FDCWD, source, descriptor, name, UInt32(RENAME_EXCL)))
    }

    /// Moves the entry `name` of this folder back out to the absolute path `destination`, never overwriting.
    func moveOut(_ name: String, toPath destination: String) throws {
        try Self.settle(renameatx_np(descriptor, name, AT_FDCWD, destination, UInt32(RENAME_EXCL)))
    }

    /// Renames `from` to `name` inside this folder, never overwriting.
    func rename(_ from: String, to name: String) throws {
        try Self.settle(renameatx_np(descriptor, from, descriptor, name, UInt32(RENAME_EXCL)))
    }

    private static func settle(_ result: Int32) throws {
        guard result == 0 else {
            switch errno {
            case EEXIST: throw QuarantineFiles.MoveFailure.destinationExists
            case EXDEV: throw QuarantineFiles.MoveFailure.crossDevice
            default: throw QuarantineError.ioFailure(QuarantineFiles.message(errno))
            }
        }
    }

    /// `fchmod` on the regular file `name` in this folder, opened without following a symlink; it must be the very
    /// file `expecting` describes (same device and inode).
    func setPermissions(_ mode: Int, of name: String, expecting: stat) throws {
        let file = openat(descriptor, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard file >= 0 else { throw QuarantineError.ioFailure(QuarantineFiles.message(errno)) }
        defer { _ = Darwin.close(file) }
        var info = stat()
        guard fstat(file, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_dev == expecting.st_dev, info.st_ino == expecting.st_ino
        else {
            throw QuarantineError.changedSinceScan
        }
        guard fchmod(file, mode_t(mode & 0o777)) == 0 else {
            throw QuarantineError.ioFailure(QuarantineFiles.message(errno))
        }
    }
}
