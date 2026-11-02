import CryptoKit
import Darwin
import Foundation
import MainternanceDomain

/// Low-level, descriptor-based file operations for the quarantine store.
///
/// Everything that decides something about a file works on an open descriptor (`O_NOFOLLOW`, `fstat`, `fchmod`)
/// instead of re-resolving a path, so a symlink swapped in after a check cannot redirect the operation.
enum QuarantineFiles {
    enum MoveFailure: Error {
        case destinationExists
        case crossDevice
    }

    struct OpenFile {
        let descriptor: Int32
        let info: stat

        func close() {
            _ = Darwin.close(descriptor)
        }
    }

    /// What `copy` wrote: its hash and size, and the identity of the new file.
    struct CopyResult {
        let hex: String
        let size: Int64
        let info: stat
    }

    private static let chunkSize = 1 << 20

    static func message(_ code: Int32) -> String {
        String(cString: strerror(code))
    }

    /// Opens a regular file without following a final symlink. `.missing`, `.notRegularFile` or `.ioFailure`.
    static func openRegular(_ path: String) throws -> OpenFile {
        let descriptor = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else {
            switch errno {
            case ENOENT, ENOTDIR: throw QuarantineError.missing
            case ELOOP: throw QuarantineError.notRegularFile
            default: throw QuarantineError.ioFailure(message(errno))
            }
        }
        var info = stat()
        guard fstat(descriptor, &info) == 0 else {
            let failure = errno
            _ = close(descriptor)
            throw QuarantineError.ioFailure(message(failure))
        }
        guard info.st_mode & S_IFMT == S_IFREG else {
            _ = close(descriptor)
            throw QuarantineError.notRegularFile
        }
        return OpenFile(descriptor: descriptor, info: info)
    }

    /// `lstat` of a path (never follows a symlink); nil when it does not exist.
    static func linkInfo(_ path: String) -> stat? {
        var info = stat()
        return lstat(path, &info) == 0 ? info : nil
    }

    static func sameFile(_ first: stat, _ second: stat) -> Bool {
        first.st_dev == second.st_dev && first.st_ino == second.st_ino && first.st_size == second.st_size
            && first.st_mode & S_IFMT == S_IFREG && second.st_mode & S_IFMT == S_IFREG
    }

    /// The physical folder of `path`: symlinks and `..` resolved. `.missing` when it does not exist.
    static func realParent(of path: String) throws -> String {
        let parent = (path as NSString).deletingLastPathComponent
        guard let real = realpath(parent, nil) else { throw QuarantineError.missing }
        defer { free(real) }
        return String(cString: real)
    }

    /// Device and inode of the folder at `path` (a physical path from `realParent`).
    static func folderIdentity(_ path: String) throws -> stat {
        var info = stat()
        guard lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else { throw QuarantineError.changedSinceScan }
        return info
    }

    /// Streams the descriptor from the start in 1 MiB chunks.
    private static func forEachChunk(_ descriptor: Int32, _ body: (UnsafeRawBufferPointer) throws -> Void) throws {
        guard lseek(descriptor, 0, SEEK_SET) >= 0 else { throw QuarantineError.ioFailure(message(errno)) }
        var buffer = [UInt8](repeating: 0, count: chunkSize)
        while true {
            let count = buffer.withUnsafeMutableBytes { read(descriptor, $0.baseAddress, $0.count) }
            if count < 0, errno == EINTR {
                continue
            }
            guard count >= 0 else { throw QuarantineError.ioFailure(message(errno)) }
            if count == 0 {
                return
            }
            try buffer.withUnsafeBytes { try body(UnsafeRawBufferPointer(rebasing: $0[0 ..< count])) }
        }
    }

    static func hash(of file: OpenFile) throws -> (hex: String, size: Int64) {
        var hasher = SHA256()
        var size: Int64 = 0
        try forEachChunk(file.descriptor) { chunk in
            hasher.update(bufferPointer: chunk)
            size += Int64(chunk.count)
        }
        return (hex(hasher.finalize()), size)
    }

    /// Hash of the regular file at `path`, or nil when it is absent, not a regular file or unreadable.
    static func hash(ofPath path: String) -> String? {
        guard let file = try? openRegular(path) else { return nil }
        defer { file.close() }
        return try? hash(of: file).hex
    }

    static func sha256Hex(of data: Data) -> String {
        hex(SHA256.hash(data: data))
    }

    private static func hex(_ digest: SHA256.Digest) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Copies the descriptor's content to a NEW file at `partial` (`O_EXCL`, mode `0o600`), hashing while copying,
    /// and flushes it. Returns the hash and size of what was written.
    static func copy(_ source: OpenFile, toNewFile partial: String) throws -> (hex: String, size: Int64) {
        let copied = try copy(source, into: AT_FDCWD, name: partial)
        return (copied.hex, copied.size)
    }

    /// Like `copy(_:toNewFile:)`, creating `name` relative to the open folder `folder` (`openat`). Also returns the
    /// identity (`fstat`) of the file it created.
    static func copy(
        _ source: OpenFile,
        into folder: Int32,
        name: String
    ) throws -> CopyResult {
        let target = openat(folder, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard target >= 0 else { throw QuarantineError.ioFailure(message(errno)) }
        defer { _ = close(target) }
        var info = stat()
        guard fstat(target, &info) == 0 else { throw QuarantineError.ioFailure(message(errno)) }
        var hasher = SHA256()
        var size: Int64 = 0
        try forEachChunk(source.descriptor) { chunk in
            hasher.update(bufferPointer: chunk)
            size += Int64(chunk.count)
            var offset = 0
            while offset < chunk.count {
                let written = write(target, chunk.baseAddress! + offset, chunk.count - offset)
                if written < 0, errno == EINTR {
                    continue
                }
                guard written > 0 else { throw QuarantineError.ioFailure(message(errno)) }
                offset += written
            }
        }
        guard fsync(target) == 0 else { throw QuarantineError.ioFailure(message(errno)) }
        return CopyResult(hex: hex(hasher.finalize()), size: size, info: info)
    }

    /// Atomic rename that fails instead of replacing an existing destination.
    static func renameNoOverwrite(_ source: String, to destination: String) throws {
        guard renamex_np(source, destination, UInt32(RENAME_EXCL)) == 0 else {
            switch errno {
            case EEXIST: throw MoveFailure.destinationExists
            case EXDEV: throw MoveFailure.crossDevice
            default: throw QuarantineError.ioFailure(message(errno))
            }
        }
    }

    /// `fchmod` on a freshly opened descriptor of the regular file at `path` (never follows a symlink).
    /// When `expecting` is given, the descriptor must be that very file.
    static func setPermissions(_ mode: Int, atPath path: String, expecting: stat? = nil) throws {
        let file = try openRegular(path)
        defer { file.close() }
        if let expecting, file.info.st_dev != expecting.st_dev || file.info.st_ino != expecting.st_ino {
            throw QuarantineError.changedSinceScan
        }
        guard fchmod(file.descriptor, mode_t(mode & 0o777)) == 0 else {
            throw QuarantineError.ioFailure(message(errno))
        }
    }

    static func isNoSuchFile(_ error: Error) -> Bool {
        let nsError = error as NSError
        let cocoaMissing = [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(nsError.code)
        if nsError.domain == NSCocoaErrorDomain, cocoaMissing {
            return true
        }
        let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError
        return underlying?.domain == NSPOSIXErrorDomain && underlying?.code == Int(ENOENT)
    }
}
