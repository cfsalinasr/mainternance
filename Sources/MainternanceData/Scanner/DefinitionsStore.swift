import Foundation

/// Reads how fresh the app-owned ClamAV virus definitions are.
public struct DefinitionsStore: Sendable {
    /// Database files ClamAV may keep (`.cvd` is a full download, `.cld` an incrementally updated copy).
    static let databaseFiles = [
        "daily.cvd", "daily.cld", "main.cvd", "main.cld", "bytecode.cvd", "bytecode.cld"
    ]

    private let paths: ClamAVPaths

    public init(paths: ClamAVPaths) {
        self.paths = paths
    }

    /// The newest modification date among the database files that exist; nil when there is none.
    /// Files whose attributes cannot be read are ignored.
    public func definitionsDate() -> Date? {
        var newest: Date?
        for name in Self.databaseFiles {
            let url = paths.databaseDirectory.appendingPathComponent(name)
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
                  let type = attributes[.type] as? FileAttributeType, type == .typeRegular,
                  let date = attributes[.modificationDate] as? Date else { continue }
            newest = max(newest ?? date, date)
        }
        return newest
    }
}
