import Foundation
import MainternanceData
import Testing

struct DiskReaderTests {
    /// Real numbers from the user's Mac: System Settings shows 278 GB free, which is the
    /// "important usage" figure (plain `volumeAvailableCapacity` says 232 GB, `df` says 216 GB).
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

    @Test func systemReaderSmoke() throws {
        let result = try #require(DiskReader().read())
        #expect(result.total > 0)
        #expect(result.free >= 0)
        #expect(result.free <= result.total)
    }
}
