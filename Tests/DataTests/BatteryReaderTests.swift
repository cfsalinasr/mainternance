import Foundation
import MainternanceData
import MainternanceDomain
import Testing

struct BatteryReaderTests {
    private func raw(
        percent: Int? = 100,
        charging: Bool? = false,
        cycles: Int? = 22,
        design: Int? = 4629,
        full: Int? = 4679
    ) -> RawBattery {
        RawBattery(
            currentPercent: percent,
            isCharging: charging,
            externalConnected: true,
            cycleCount: cycles,
            designCapacity: design,
            fullChargeCapacity: full
        )
    }

    @Test func mapsRealMacValues() {
        let snap = BatteryReader.map(raw())
        #expect(snap == BatterySnapshot(percent: 100, isCharging: false, healthPercent: 100, cycleCount: 22))
    }

    @Test func computesHealthBelowFull() {
        #expect(BatteryReader.map(raw(full: 4397))?.healthPercent == 95)
    }

    @Test func healthIsClampedAtAndAboveHundred() {
        #expect(BatteryReader.map(raw(full: 4629))?.healthPercent == 100)
        #expect(BatteryReader.map(raw(full: 9000))?.healthPercent == 100)
        #expect(BatteryReader.map(raw(full: -10))?.healthPercent == 0)
    }

    @Test func healthNilWhenCapacityUnusable() {
        #expect(BatteryReader.map(raw(design: 0))?.healthPercent == nil)
        #expect(BatteryReader.map(raw(design: -5))?.healthPercent == nil)
        #expect(BatteryReader.map(raw(design: nil))?.healthPercent == nil)
        #expect(BatteryReader.map(raw(full: nil))?.healthPercent == nil)
    }

    @Test func clampsPercent() {
        #expect(BatteryReader.map(raw(percent: 140))?.percent == 100)
        #expect(BatteryReader.map(raw(percent: -5))?.percent == 0)
    }

    @Test func chargingDefaultsToFalseAndPassesThrough() {
        #expect(BatteryReader.map(raw(charging: nil))?.isCharging == false)
        #expect(BatteryReader.map(raw(charging: true))?.isCharging == true)
    }

    @Test func negativeOrMissingCyclesAreNil() {
        #expect(BatteryReader.map(raw(cycles: -1))?.cycleCount == nil)
        #expect(BatteryReader.map(raw(cycles: nil))?.cycleCount == nil)
        #expect(BatteryReader.map(raw(cycles: 0))?.cycleCount == 0)
    }

    @Test func nilRawOrNilPercentIsNil() {
        #expect(BatteryReader.map(nil) == nil)
        #expect(BatteryReader.map(raw(percent: nil)) == nil)
    }

    @Test func readMapsInjectedRaw() {
        let value = raw(percent: 50, charging: true)
        #expect(BatteryReader(read: { value }).read()?.percent == 50)
        #expect(BatteryReader(read: { nil }).read() == nil)
    }

    @Test func systemReaderSmoke() {
        guard let snap = BatteryReader().read() else { return }
        #expect((0 ... 100).contains(snap.percent))
        if let health = snap.healthPercent {
            #expect((0 ... 100).contains(health))
        }
        if let cycles = snap.cycleCount {
            #expect(cycles >= 0)
        }
    }
}
