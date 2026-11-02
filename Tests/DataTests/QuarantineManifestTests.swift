import Foundation
@testable import MainternanceData
import MainternanceDomain
import Testing

@Suite("Quarantine manifest format and crash recovery")
struct QuarantineManifestTests {
    private static let idText = "6F9619FF-8B86-D011-B42D-00C04FC964FF"
    private static let sha = String(repeating: "ab", count: 32)

    private func literal(state: String, path: String = "/Users/x/Downloads/eicar.com") -> String {
        """
        [{"state":"\(state)","record":{"id":"\(Self.idText)","originalPath":"\(path)",\
        "quarantinedAt":1700000000,"signature":"Eicar-Test-Signature","sha256":"\(Self.sha)",\
        "size":9000000000,"originalPermissions":493}}]
        """
    }

    @Test("a hard-coded index.json decodes into the records, with every field")
    func decodesLiteral() async throws {
        let fix = try QuarantineFixture()
        try FileManager.default.createDirectory(at: fix.vault, withIntermediateDirectories: true)
        try Data(literal(state: "stored").utf8).write(to: fix.manifestURL)
        try Data("x".utf8).write(to: fix.vault.appendingPathComponent(Self.idText))
        let records = await fix.store.records()
        let record = try #require(records.first)
        #expect(records.count == 1)
        #expect(record.id == UUID(uuidString: Self.idText))
        #expect(record.originalPath == "/Users/x/Downloads/eicar.com")
        #expect(record.quarantinedAt == Date(timeIntervalSince1970: 1_700_000_000))
        #expect(record.signature == "Eicar-Test-Signature")
        #expect(record.sha256 == Self.sha)
        #expect(record.size == 9_000_000_000)
        #expect(record.originalPermissions == 0o755)
    }

    @Test("encoding writes exactly these key names and seconds-since-1970 dates")
    func encodedKeys() throws {
        let id = try #require(UUID(uuidString: Self.idText))
        let record = QuarantineRecord(
            id: id, originalPath: "/p", quarantinedAt: Date(timeIntervalSince1970: 1_700_000_000), signature: "S",
            sha256: Self.sha, size: 9, originalPermissions: 0o644
        )
        let data = try QuarantineManifest.encode([QuarantineManifest.Entry(state: .pending, record: record)])
        let array = try #require(try JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        let entry = try #require(array.first)
        #expect(Set(entry.keys) == ["state", "record"])
        #expect(entry["state"] as? String == "pending")
        let fields = try #require(entry["record"] as? [String: Any])
        #expect(Set(fields.keys) == [
            "id", "originalPath", "quarantinedAt", "signature", "sha256", "size", "originalPermissions"
        ])
        let seconds = try #require(fields["quarantinedAt"] as? Double)
        #expect(abs(seconds - 1_700_000_000) < 1e-6)
        let decoded = try QuarantineManifest.decode(data)
        #expect(decoded.first?.record == record)
    }

    @Test("crash after the pending entry and the move: the file is recovered into the list")
    func pendingWithMovedFile() async throws {
        let fix = try QuarantineFixture()
        try FileManager.default.createDirectory(at: fix.vault, withIntermediateDirectories: true)
        try Data(literal(state: "pending", path: fix.area.appendingPathComponent("gone.txt").path).utf8)
            .write(to: fix.manifestURL)
        try Data("x".utf8).write(to: fix.vault.appendingPathComponent(Self.idText))
        let records = await fix.store.records()
        #expect(records.count == 1)
        let restored = try await fix.store.restore(#require(records.first).id)
        #expect(restored == fix.area.appendingPathComponent("gone.txt").path)
        #expect(try String(contentsOfFile: restored, encoding: .utf8) == "x")
    }

    @Test("crash after the pending entry but before the move: the original is untouched and the entry dropped")
    func pendingWithoutMove() async throws {
        let fix = try QuarantineFixture()
        let original = try fix.makeFile("keep.txt", "still here")
        try FileManager.default.createDirectory(at: fix.vault, withIntermediateDirectories: true)
        try Data(literal(state: "pending", path: original.path).utf8).write(to: fix.manifestURL)
        #expect(await fix.store.records().isEmpty)
        #expect(try String(contentsOf: original, encoding: .utf8) == "still here")
        // The next write persists the cleanup, and the dropped entry never comes back.
        let other = try await fix.store.quarantine(path: fix.makeFile("b.txt").path, signature: "S")
        let again = QuarantineStore(directory: fix.vault, now: { Date() })
        #expect(await again.records() == [other])
    }

    @Test("an interrupted cross-volume copy leaves only a partial file, which the sweep removes; the original stays")
    func partialCopy() async throws {
        let fix = try QuarantineFixture()
        let original = try fix.makeFile("keep.txt", "still here")
        try FileManager.default.createDirectory(at: fix.vault, withIntermediateDirectories: true)
        let partial = fix.vault.appendingPathComponent("\(Self.idText).partial")
        try Data("half".utf8).write(to: partial)
        try Data(literal(state: "pending", path: original.path).utf8).write(to: fix.manifestURL)
        #expect(await fix.store.records().isEmpty)
        #expect(!fix.exists(partial))
        #expect(try String(contentsOf: original, encoding: .utf8) == "still here")
    }

    @Test("a stored record whose quarantined file is gone (restored just before a crash) is dropped from the list")
    func storedWithoutFile() async throws {
        let fix = try QuarantineFixture()
        try FileManager.default.createDirectory(at: fix.vault, withIntermediateDirectories: true)
        try Data(literal(state: "stored").utf8).write(to: fix.manifestURL)
        #expect(await fix.store.records().isEmpty)
    }

    @Test("quarantine writes the manifest as stored, and no pending entry is left behind")
    func finalState() async throws {
        let fix = try QuarantineFixture()
        _ = try await fix.store.quarantine(path: fix.makeFile("a.txt").path, signature: "S")
        let entries = try QuarantineManifest.decode(Data(contentsOf: fix.manifestURL))
        #expect(entries.map(\.state) == [.stored])
    }
}
