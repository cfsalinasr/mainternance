import MainternanceData
import Testing

struct GPUReaderTests {
    @Test func mapsPercentToFraction() throws {
        let value = try #require(GPUReader.map(34))
        #expect(abs(value - 0.34) < 1e-9)
    }

    @Test func clampsOutOfRange() throws {
        #expect(try #require(GPUReader.map(150)) == 1.0)
        #expect(try #require(GPUReader.map(-3)) == 0.0)
        #expect(try #require(GPUReader.map(Int.max)) == 1.0)
        #expect(try #require(GPUReader.map(Int.min)) == 0.0)
    }

    @Test func missingIsNil() {
        #expect(GPUReader.map(nil) == nil)
    }

    @Test func usageMapsInjectedValue() throws {
        let value = try #require(GPUReader(read: { 50 }).usage())
        #expect(abs(value - 0.5) < 1e-9)
        #expect(GPUReader(read: { nil }).usage() == nil)
    }

    @Test func systemReaderSmoke() {
        if let value = GPUReader().usage() {
            #expect(value.isFinite && (0 ... 1).contains(value))
        }
    }
}
