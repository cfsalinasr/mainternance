import Foundation
import MainternanceData
import MainternanceDomain
import Synchronization
import Testing

private let gigabyte: Int64 = 1_000_000_000

private func sequencedCPU(_ ticks: [CPUTicks?]) -> CPUReader {
    let index = Mutex(0)
    return CPUReader(read: {
        index.withLock { position in
            defer { position += 1 }
            return position < ticks.count ? ticks[position] : ticks.last ?? nil
        }
    })
}

private let busyTicks = [
    CPUTicks(user: 100, system: 100, idle: 800, nice: 0),
    CPUTicks(user: 150, system: 150, idle: 900, nice: 0)
]

private struct Readers {
    var disk = DiskReader(read: { _ in RawDisk(total: 494 * gigabyte, importantFree: 278 * gigabyte) })
    var memory = MemoryPressureReader(read: { 1 })
    var thermal = ThermalReader(read: { .nominal })
    var battery = BatteryReader(read: {
        RawBattery(
            currentCapacity: 100, maxCapacity: 100, isCharging: false, externalConnected: true,
            cycleCount: 22, designCapacity: 4629, fullChargeCapacity: 4679
        )
    })
    var cpu = sequencedCPU(busyTicks)
    var gpu = GPUReader(read: { 34 })

    var provider: LiveSystemSnapshotProvider {
        LiveSystemSnapshotProvider(disk: disk, memory: memory, thermal: thermal, battery: battery, cpu: cpu, gpu: gpu)
    }
}

private let expectedBattery = BatterySnapshot(percent: 100, isCharging: false, healthPercent: 100, cycleCount: 22)

struct LiveSystemSnapshotProviderTests {
    @Test func allReadersPresentComposeTheExpectedSnapshot() async throws {
        let provider = Readers().provider
        _ = await provider.currentSnapshot() // CPU baseline
        let snapshot = await provider.currentSnapshot()
        let cpu = try #require(snapshot.cpuUsage)
        #expect(abs(cpu - 0.5) < 1e-9)
        let gpu = try #require(snapshot.gpuUsage)
        #expect(abs(gpu - 0.34) < 1e-9)
        var rest = snapshot
        rest.cpuUsage = nil
        rest.gpuUsage = nil
        #expect(rest == SystemSnapshot(
            diskTotalBytes: 494 * gigabyte, diskFreeBytes: 278 * gigabyte, memoryPressure: .normal,
            thermal: .nominal, cpuUsage: nil, gpuUsage: nil, temperatureCelsius: nil,
            battery: expectedBattery, newStartupItemCount: nil, osUpdateAvailable: nil
        ))
    }

    @Test func firstSnapshotHasNoCpuAndSecondHasOne() async {
        let provider = Readers().provider
        let first = await provider.currentSnapshot()
        let second = await provider.currentSnapshot()
        #expect(first.cpuUsage == nil)
        #expect(second.cpuUsage != nil)
    }

    @Test func unreadableDiskGivesZeroTotalAndFreeAndTheEvaluatorSaysSo() async {
        var readers = Readers()
        readers.disk = DiskReader(read: { _ in nil })
        let snapshot = await readers.provider.currentSnapshot()
        #expect(snapshot.diskTotalBytes == 0)
        #expect(snapshot.diskFreeBytes == 0)
        let report = HealthEvaluator().evaluate(snapshot: snapshot, scan: nil, now: Date())
        #expect(report.checks.first { $0.id == .diskSpace }?.reason == "Disk size unavailable")
    }

    @Test func unknownMemoryStaysNilAndOmitsTheCheck() async {
        var readers = Readers()
        readers.memory = MemoryPressureReader(read: { nil })
        let snapshot = await readers.provider.currentSnapshot()
        #expect(snapshot.memoryPressure == nil)
        let report = HealthEvaluator().evaluate(snapshot: snapshot, scan: nil, now: Date())
        #expect(!report.checks.contains { $0.id == .memoryPressure })
    }

    @Test func missingBatteryAndGpuAreNil() async {
        var readers = Readers()
        readers.battery = BatteryReader(read: { nil })
        readers.gpu = GPUReader(read: { nil })
        let snapshot = await readers.provider.currentSnapshot()
        #expect(snapshot.battery == nil)
        #expect(snapshot.gpuUsage == nil)
    }

    @Test func unreadableCpuStaysNil() async {
        var readers = Readers()
        readers.cpu = sequencedCPU([nil])
        let provider = readers.provider
        _ = await provider.currentSnapshot()
        #expect(await provider.currentSnapshot().cpuUsage == nil)
    }

    @Test func thermalIsPassedThrough() async {
        var readers = Readers()
        readers.thermal = ThermalReader(read: { .serious })
        #expect(await readers.provider.currentSnapshot().thermal == .serious)
    }

    @Test func fieldsWithoutAnEngineAreAlwaysNil() async {
        let snapshot = await Readers().provider.currentSnapshot()
        #expect(snapshot.temperatureCelsius == nil)
        #expect(snapshot.newStartupItemCount == nil)
        #expect(snapshot.osUpdateAvailable == nil)
    }

    @Test func endToEndReportHasOnlyTheChecksThatCanBeMade() async {
        let load = LoadOverview(
            snapshots: Readers().provider, scans: NoScannerStatusProvider(), actions: NoSuggestedActionsProvider()
        )
        let overview = await load()
        #expect(overview.scan == nil)
        #expect(overview.actions.isEmpty)
        #expect(overview.report.checks.map(\.id) == [.diskSpace, .memoryPressure, .thermal, .batteryHealth])
        #expect(overview.report.overall == .good)
    }

    @Test func endToEndWithUnknownMemoryAndNoBatteryKeepsDiskAndThermalOnly() async {
        var readers = Readers()
        readers.memory = MemoryPressureReader(read: { nil })
        readers.battery = BatteryReader(read: { nil })
        let load = LoadOverview(
            snapshots: readers.provider, scans: NoScannerStatusProvider(), actions: NoSuggestedActionsProvider()
        )
        let overview = await load()
        #expect(overview.report.checks.map(\.id) == [.diskSpace, .thermal])
        #expect(overview.report.overall == .good)
    }

    @Test func emptyProvidersReturnNothing() async {
        #expect(await NoScannerStatusProvider().currentStatus() == nil)
        #expect(await NoSuggestedActionsProvider().suggestedActions().isEmpty)
    }

    @Test func realMachineSmokeTest() async {
        let snapshot = await LiveSystemSnapshotProvider().currentSnapshot()
        #expect(snapshot.diskTotalBytes > 0)
        #expect(snapshot.diskFreeBytes <= snapshot.diskTotalBytes)
    }
}
