import Foundation
import MainternanceDomain

/// The on-disk format of `<quarantine>/index.json`: a JSON array of entries, one per quarantined file.
///
/// Date strategy: `quarantinedAt` is seconds since 1970 (`.secondsSince1970`) in both the encoder and the decoder,
/// so the file does not depend on locale or time zone (the same strategy the domain tests use).
/// Key names are the synthesized `Codable` names of `QuarantineRecord`; `QuarantineManifestTests` pins them.
enum QuarantineManifest {
    enum State: String, Codable, Sendable {
        /// Written BEFORE the file is moved. After a crash, the entry is resolved by looking at the vault.
        case pending
        /// The move finished: the file is in quarantine and can be restored.
        case stored
    }

    struct Entry: Codable, Sendable, Equatable {
        var state: State
        let record: QuarantineRecord
    }

    static func encode(_ entries: [Entry]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(entries)
    }

    static func decode(_ data: Data) throws -> [Entry] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try decoder.decode([Entry].self, from: data)
    }
}
