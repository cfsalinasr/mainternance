import Foundation
import MainternanceData
import MainternanceDomain
import Testing

struct BatteryReaderTests {
    private func raw(
        percent: Int? = 100,
        max: Int? = 100,
        charging: Bool? = false,
        cycles: Int? = 22,
        design: Int? = 4629,
        full: Int? = 4679
    ) -> RawBattery {
        RawBattery(
            currentCapacity: percent,
            maxCapacity: max,
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

    // MARK: percent from current and max capacity

    @Test func percentIsCurrentOverMaxWhenMaxIsKnown() {
        #expect(BatteryReader.map(raw(percent: 3000, max: 6000))?.percent == 50) // Intel-style mAh
        #expect(BatteryReader.map(raw(percent: 100, max: 100))?.percent == 100) // Apple silicon percent
        #expect(BatteryReader.map(raw(percent: 1, max: 3))?.percent == 33)
        #expect(BatteryReader.map(raw(percent: 2, max: 3))?.percent == 67)
    }

    @Test func percentFromCapacitiesIsClamped() {
        #expect(BatteryReader.map(raw(percent: 7000, max: 6000))?.percent == 100)
        #expect(BatteryReader.map(raw(percent: -10, max: 6000))?.percent == 0)
    }

    @Test func unusableMaxFallsBackToCurrentAsPercent() {
        #expect(BatteryReader.map(raw(percent: 80, max: nil))?.percent == 80)
        #expect(BatteryReader.map(raw(percent: 80, max: 0))?.percent == 80)
        #expect(BatteryReader.map(raw(percent: 80, max: -5))?.percent == 80)
    }

    // MARK: registry dictionary parsing

    /// The user's Apple silicon Mac, as `AppleSmartBattery` reports it.
    private let appleSilicon: [String: Any] = [
        "CurrentCapacity": 100, "MaxCapacity": 100, "CycleCount": 22,
        "IsCharging": false, "ExternalConnected": true,
        "BatteryData": ["DesignCapacity": 4629, "FullChargeCapacity": 4679] as [String: Any]
    ]

    @Test func parsesRealAppleSiliconValues() throws {
        let parsed = try #require(BatteryReader.parse(appleSilicon))
        #expect(parsed == RawBattery(
            currentCapacity: 100, maxCapacity: 100, isCharging: false, externalConnected: true,
            cycleCount: 22, designCapacity: 4629, fullChargeCapacity: 4679
        ))
        #expect(BatteryReader.map(parsed) == BatterySnapshot(
            percent: 100, isCharging: false, healthPercent: 100, cycleCount: 22
        ))
    }

    @Test func parsesIntelStyleMilliampHours() throws {
        let parsed = try #require(BatteryReader.parse(["CurrentCapacity": 3000, "MaxCapacity": 6000]))
        #expect(BatteryReader.map(parsed)?.percent == 50)
    }

    @Test func fullChargeFallsBackToAppleRawMaxCapacity() throws {
        let props: [String: Any] = [
            "CurrentCapacity": 90, "AppleRawMaxCapacity": 4397,
            "BatteryData": ["DesignCapacity": 4629] as [String: Any]
        ]
        let parsed = try #require(BatteryReader.parse(props))
        #expect(parsed.fullChargeCapacity == 4397)
        #expect(parsed.designCapacity == 4629)
        #expect(BatteryReader.map(parsed)?.healthPercent == 95)
    }

    @Test func batteryDataWinsOverTopLevelValues() throws {
        var props = appleSilicon
        props["DesignCapacity"] = 1
        props["AppleRawMaxCapacity"] = 1
        let parsed = try #require(BatteryReader.parse(props))
        #expect(parsed.designCapacity == 4629)
        #expect(parsed.fullChargeCapacity == 4679)
    }

    @Test func designFallsBackToTopLevelDesignCapacity() throws {
        let props: [String: Any] = [
            "CurrentCapacity": 90, "DesignCapacity": 5000,
            "BatteryData": ["FullChargeCapacity": 4500] as [String: Any]
        ]
        let parsed = try #require(BatteryReader.parse(props))
        #expect(parsed.designCapacity == 5000)
        #expect(BatteryReader.map(parsed)?.healthPercent == 90)
    }

    @Test func missingBatteryDataUsesTopLevelOrNil() throws {
        let bare = try #require(BatteryReader.parse(["CurrentCapacity": 55, "MaxCapacity": 100]))
        #expect(bare.designCapacity == nil)
        #expect(bare.fullChargeCapacity == nil)
        #expect(BatteryReader.map(bare) == BatterySnapshot(
            percent: 55, isCharging: false, healthPercent: nil, cycleCount: nil
        ))
    }

    @Test func wrongValueTypesAndNegativeNumbersAreIgnored() throws {
        let props: [String: Any] = [
            "CurrentCapacity": "100", "MaxCapacity": -100, "CycleCount": -3,
            "IsCharging": "yes", "ExternalConnected": "no",
            "DesignCapacity": -4629, "AppleRawMaxCapacity": "4679",
            "BatteryData": "not a dictionary"
        ]
        let parsed = try #require(BatteryReader.parse(props))
        #expect(parsed == RawBattery(
            currentCapacity: nil, maxCapacity: nil, isCharging: nil, externalConnected: nil,
            cycleCount: nil, designCapacity: nil, fullChargeCapacity: nil
        ))
        #expect(BatteryReader.map(parsed) == nil)
        let nested: [String: Any] = [
            "CurrentCapacity": 50,
            "BatteryData": ["DesignCapacity": "4629", "FullChargeCapacity": -1] as [String: Any]
        ]
        let nestedParsed = try #require(BatteryReader.parse(nested))
        #expect(nestedParsed.designCapacity == nil)
        #expect(nestedParsed.fullChargeCapacity == nil)
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
