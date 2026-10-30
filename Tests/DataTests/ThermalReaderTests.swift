import Foundation
import MainternanceData
import MainternanceDomain
import Testing

struct ThermalReaderTests {
    @Test func mapsAllKnownStates() {
        #expect(ThermalReader.map(.nominal) == .nominal)
        #expect(ThermalReader.map(.fair) == .fair)
        #expect(ThermalReader.map(.serious) == .serious)
        #expect(ThermalReader.map(.critical) == .critical)
    }

    @Test func readMapsInjectedState() {
        #expect(ThermalReader(read: { .critical }).read() == .critical)
    }

    @Test func systemReaderSmoke() {
        let level = ThermalReader().read()
        #expect([ThermalLevel.nominal, .fair, .serious, .critical].contains(level))
    }
}
