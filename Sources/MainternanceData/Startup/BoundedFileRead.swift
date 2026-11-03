import Darwin
import Foundation

/// Reads one small file through a single descriptor opened non-blocking (a FIFO cannot hang the reader) and checked
/// with `fstat` on that same descriptor (no swap between the check and the read): a regular file of at most
/// `maxBytes`, or a reason it was not read. No exists-then-read.
enum BoundedFileRead {
    enum Failure: Error, Equatable {
        /// Nothing at the path.
        case missing
        case cannotOpen(String)
        case notRegularFile
        case tooLarge
    }

    static func data(at path: String, maxBytes: Int) -> Result<Data, Failure> {
        let descriptor = open(path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else {
            let code = errno
            return .failure(code == ENOENT ? .missing : .cannotOpen(String(cString: strerror(code))))
        }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { return .failure(.notRegularFile) }
        guard info.st_size <= maxBytes else { return .failure(.tooLarge) }
        var data = Data()
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        while data.count <= maxBytes {
            let count = chunk.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, $0.count) }
            if count > 0 {
                data.append(contentsOf: chunk[0 ..< count])
            } else if count == 0 {
                return .success(data)
            } else if errno != EINTR {
                return .failure(.cannotOpen(String(cString: strerror(errno))))
            }
        }
        return .failure(.tooLarge) // it grew past the limit after it was checked
    }
}
