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

extension QuarantineManifest {
    /// The per-file sidecar `<uuid>.json` holds one bare `QuarantineRecord` (same keys and date strategy as the
    /// manifest entries' `record`). It is written before the file moves, so a lost or corrupt `index.json`
    /// can be rebuilt from the sidecars.
    static func encodeRecord(_ record: QuarantineRecord) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(record)
    }

    static func decodeRecord(_ data: Data) throws -> QuarantineRecord {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try decoder.decode(QuarantineRecord.self, from: data)
    }
}
