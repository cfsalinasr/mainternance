import Foundation

/// Writes one of the app's own small JSON files: keys sorted, dates in seconds since 1970, the folder created
/// `0o700` when missing, the file written atomically and then set to `0o600`. Failures are silent: the caller's
/// file simply stays as it was.
enum PrivateJSONFile {
    static func write(_ value: some Encodable, to file: URL) {
        let manager = FileManager.default
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(value) else { return }
        try? manager.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        guard (try? data.write(to: file, options: .atomic)) != nil else { return }
        try? manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
}
