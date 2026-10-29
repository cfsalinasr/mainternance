import Foundation
import MainternanceData
import Testing

struct DiskReaderTests {
    /// Real numbers measured on the user's Mac: System Settings showed 278 GB free, the "important usage"
    /// figure (on that Mac plain `volumeAvailableCapacity` said 232 GB and `df` 216 GB).
    private let total: Int64 = 494_332_366_848
    private let importantFree: Int64 = 278_333_262_487

    @Test func mapsRealImportantUsageNumbersUnchanged() throws {
        let result = try #require(DiskReader.map(RawDisk(total: total, importantFree: importantFree)))
        #expect(result.total == total)
        #expect(result.free == importantFree)
    }

    @Test func clampsFreeAboveTotalToTotal() throws {
        let result = try #require(DiskReader.map(RawDisk(total: 100, importantFree: 150)))
        #expect(result.free == 100)
    }

    @Test func clampsNegativeFreeToZero() throws {
        let result = try #require(DiskReader.map(RawDisk(total: 100, importantFree: -5)))
        #expect(result.free == 0)
    }

    @Test func invalidTotalIsNil() {
        #expect(DiskReader.map(RawDisk(total: 0, importantFree: 10)) == nil)
        #expect(DiskReader.map(RawDisk(total: -1, importantFree: 10)) == nil)
        #expect(DiskReader.map(RawDisk(total: nil, importantFree: 10)) == nil)
    }

    @Test func missingFreeIsNil() {
        #expect(DiskReader.map(RawDisk(total: 100, importantFree: nil)) == nil)
    }

    @Test func nilRawIsNil() {
        #expect(DiskReader.map(nil) == nil)
    }

    @Test func readUsesInjectedRawReaderAndVolumeURL() throws {
        let url = URL(fileURLWithPath: "/Volumes/Test")
        let reader = DiskReader(volumeURL: url) { requested in
            requested == url ? RawDisk(total: 1000, importantFree: 400) : nil
        }
        let result = try #require(reader.read())
        #expect(result.total == 1000)
        #expect(result.free == 400)
    }

    @Test func freeEqualToTotalIsKept() throws {
        let result = try #require(DiskReader.map(RawDisk(total: 100, importantFree: 100)))
        #expect(result.total == 100)
        #expect(result.free == 100)
    }

    @Test func zeroFreeIsKept() throws {
        let result = try #require(DiskReader.map(RawDisk(total: 100, importantFree: 0)))
        #expect(result.free == 0)
    }

    @Test func smallestValidTotalIsKept() throws {
        let result = try #require(DiskReader.map(RawDisk(total: 1, importantFree: 1)))
        #expect(result.total == 1)
        #expect(result.free == 1)
        let clamped = try #require(DiskReader.map(RawDisk(total: 1, importantFree: 5)))
        #expect(clamped.free == 1)
    }

    /// Regression guard for a stale figure: Foundation caches resource values on a URL instance, so a
    /// reader that keeps one URL must not keep returning its first answer. The reused reader reads once
    /// (filling any cache), 256 MB are written and flushed, then it must agree with a brand-new reader
    /// within 128 MB. Comparing with a fresh reader (not with a fixed drop) keeps it robust when other
    /// processes free or use space at the same time.
    @Test func reusedSystemReaderTracksFreeSpaceChanges() throws {
        let volume = FileManager.default.temporaryDirectory
        let reused = DiskReader(volumeURL: volume)
        let before = try #require(reused.read()).free
        let written: Int64 = 256 * 1024 * 1024
        let file = volume.appendingPathComponent("mainternance-disk-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: file) }
        try writeFlushed(bytes: Int(written), to: file)

        // A new URL instance from the path: copies of `volume` share one cache, which would hide the bug.
        let fresh = try #require(DiskReader(volumeURL: URL(fileURLWithPath: volume.path)).read()).free
        let again = try #require(reused.read()).free
        // Precondition: the write really lowered free space, otherwise the comparison below proves nothing.
        try #require(before - fresh > written / 2)
        #expect(abs(again - fresh) < written / 2)
    }

    private func writeFlushed(bytes: Int, to file: URL) throws {
        #expect(FileManager.default.createFile(atPath: file.path, contents: nil))
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        let chunk = Data(repeating: 0xA5, count: 8 * 1024 * 1024)
        for _ in 0 ..< bytes / chunk.count {
            try handle.write(contentsOf: chunk)
        }
        try handle.synchronize()
    }

    @Test func systemReaderSmoke() throws {
        let result = try #require(DiskReader().read())
        #expect(result.total > 0)
        #expect(result.free >= 0)
        #expect(result.free <= result.total)
    }
}
