import MainternanceData
import MainternanceDomain
import Testing

struct MemoryPressureReaderTests {
    @Test func mapsKnownLevels() {
        #expect(MemoryPressureReader.map(1) == .normal)
        #expect(MemoryPressureReader.map(2) == .warning)
        #expect(MemoryPressureReader.map(4) == .critical)
    }

    @Test func unknownLevelsAreNil() {
        for level: Int32? in [0, 3, 8, -1, nil] {
            #expect(MemoryPressureReader.map(level) == nil)
        }
    }

    @Test func readMapsInjectedValue() {
        #expect(MemoryPressureReader(read: { 2 }).read() == .warning)
        #expect(MemoryPressureReader(read: { nil }).read() == nil)
    }

    @Test func systemReaderSmoke() {
        #expect(MemoryPressureReader().read() != nil)
    }
}
