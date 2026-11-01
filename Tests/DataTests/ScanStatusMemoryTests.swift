import Foundation
@testable import MainternanceData
import MainternanceDomain
import Testing

/// Incomplete-scan counts, the quarantine link and damaged records.
@Suite("Scan status memory")
struct ScanStatusMemoryTests {
    private let now = Date(timeIntervalSince1970: 1_800_100_000)

    private func summary(cancelled: Bool = false, unattributed: Int = 0) -> ScanSummary {
        ScanSummary(
            scope: .quick, scanned: 10, unreadable: 0, findings: 0, startedAt: now.addingTimeInterval(-70),
            endedAt: now.addingTimeInterval(-60), cancelled: cancelled, definitionsDate: nil,
            unattributedDetections: unattributed
        )
    }

    private func finding(_ index: Int, foundAt: TimeInterval = 1_800_000_050) -> ScanFinding {
        ScanFinding(
            id: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", index)) ?? UUID(),
            path: "/Users/someone/Downloads/file \(index).bin", signature: "Win.Test.EICAR_HDB-\(index)",
            foundAt: Date(timeIntervalSince1970: foundAt)
        )
    }

    private func file(_ temp: TempDirectory) -> URL {
        temp.url.appendingPathComponent("scan-status.json")
    }

    @Test("the incomplete-scan count and the quarantine link survive a restart")
    func roundTrip() async throws {
        let temp = try TempDirectory()
        let record = try #require(UUID(uuidString: "11111111-1111-1111-1111-111111111111"))
        let memory = ScanMemory(
            findings: [finding(1)], unattributedFromIncompleteScan: 4, resolvedByQuarantine: [record: finding(2)]
        )
        await ScanStatusStore(file: file(temp)).remember(memory)
        let loaded = try #require(await ScanStatusStore(file: file(temp)).load())
        #expect(loaded.findings == [finding(1)])
        #expect(loaded.unattributedFromIncompleteScan == 4)
        #expect(loaded.resolvedByQuarantine == [record: finding(2)])
        #expect(!loaded.summaryUnreadable)
    }

    @Test("a cancelled scan stores its memory but never replaces the last completed scan")
    func cancelledKeepsLastScan() async throws {
        let temp = try TempDirectory()
        let sut = ScanStatusStore(file: file(temp))
        let completed = summary()
        await sut.recordScan(completed, memory: ScanMemory(findings: []))
        await sut.recordScan(
            summary(cancelled: true, unattributed: 3),
            memory: ScanMemory(findings: [finding(1)], unattributedFromIncompleteScan: 3)
        )
        let loaded = try #require(await sut.load())
        #expect(loaded.summary == completed)
        #expect(loaded.unattributedFromIncompleteScan == 3)
        #expect(loaded.findings == [finding(1)])
    }

    @Test("remembering keeps the last scan; a completed scan replaces the incomplete count")
    func completedReplacesTheCount() async throws {
        let temp = try TempDirectory()
        let sut = ScanStatusStore(file: file(temp))
        let completed = summary()
        await sut.recordScan(completed, memory: ScanMemory(findings: []))
        await sut.remember(ScanMemory(findings: [], unattributedFromIncompleteScan: 2))
        #expect(await sut.load()?.summary == completed)
        #expect(await sut.load()?.unattributedFromIncompleteScan == 2)
        await sut.recordScan(summary(), memory: ScanMemory(findings: [], unattributedFromIncompleteScan: 0))
        #expect(await sut.load()?.unattributedFromIncompleteScan == 0)
    }

    @Test("the new fields are pinned in the file format, and an older file without them loads with defaults")
    func pinnedFormat() async throws {
        let temp = try TempDirectory()
        let json = """
        {"version":1,"findings":[],"unattributedFromIncompleteScan":5,
        "resolvedByQuarantine":[{"recordID":"11111111-1111-1111-1111-111111111111",
        "finding":{"id":"00000000-0000-0000-0000-000000000007","path":"/Users/x/a.bin",
        "signature":"Sig","foundAt":1800000020}}]}
        """
        try Data(json.utf8).write(to: file(temp))
        let loaded = try #require(await ScanStatusStore(file: file(temp)).load())
        #expect(loaded.unattributedFromIncompleteScan == 5)
        #expect(loaded.resolvedByQuarantine.count == 1)
        #expect(loaded.resolvedByQuarantine.values.first?.path == "/Users/x/a.bin")
        let older = #"{"version":1,"findings":[]}"#
        try Data(older.utf8).write(to: file(temp))
        let defaults = try #require(await ScanStatusStore(file: file(temp)).load())
        #expect(defaults.unattributedFromIncompleteScan == 0)
        #expect(defaults.resolvedByQuarantine.isEmpty)
    }

    @Test("one damaged link entry is skipped; findings, summary and the good links stay")
    func damagedLink() async throws {
        let temp = try TempDirectory()
        let json = """
        {"version":1,"findings":[{"id":"00000000-0000-0000-0000-000000000001","path":"/Users/x/a.bin",
        "signature":"Sig","foundAt":1800000020}],
        "lastScan":{"scope":"quick","scanned":1,"unreadable":0,"permissionDenied":0,"findings":0,
        "startedAt":1800000000,"endedAt":1800000001,"cancelled":false},
        "resolvedByQuarantine":[
        {"recordID":"nope","finding":{"id":"00000000-0000-0000-0000-000000000007","path":"/a",
        "signature":"s","foundAt":1}},
        {"recordID":"11111111-1111-1111-1111-111111111111","finding":{"id":"00000000-0000-0000-0000-000000000008",
        "path":"relative","signature":"s","foundAt":1}},
        {"recordID":"22222222-2222-2222-2222-222222222222","finding":{"id":"00000000-0000-0000-0000-000000000009",
        "path":"/Users/x/good.bin","signature":"s","foundAt":1}}]}
        """
        try Data(json.utf8).write(to: file(temp))
        let loaded = try #require(await ScanStatusStore(file: file(temp)).load())
        #expect(loaded.findings.count == 1)
        #expect(loaded.summary != nil)
        #expect(loaded.resolvedByQuarantine.count == 1)
        #expect(loaded.resolvedByQuarantine.values.first?.path == "/Users/x/good.bin")
    }

    @Test("an unreadable file is moved aside, never overwritten, when the next save happens")
    func unreadableFileIsKeptAside() async throws {
        let temp = try TempDirectory()
        try Data("this is not json".utf8).write(to: file(temp))
        let sut = ScanStatusStore(file: file(temp))
        #expect(await sut.load() == nil)
        await sut.remember(ScanMemory(findings: [finding(1)]))
        #expect(await sut.load()?.findings == [finding(1)])
        let aside = temp.names.filter { $0.hasPrefix("scan-status.corrupt-") }
        #expect(aside.count == 1)
        let kept = try Data(contentsOf: temp.url.appendingPathComponent(#require(aside.first)))
        #expect(String(bytes: kept, encoding: .utf8) == "this is not json")
        await sut.remember(ScanMemory(findings: []))
        #expect(temp.names.filter { $0.hasPrefix("scan-status.corrupt-") }.count == 1) // a good file is not moved
    }

    @Test("a missing file is not 'moved aside'")
    func missingFileNothingToKeep() async throws {
        let temp = try TempDirectory()
        await ScanStatusStore(file: file(temp)).remember(ScanMemory(findings: []))
        #expect(temp.names == ["scan-status.json"])
    }

    @Test("the scan-did-not-finish flag and the unattributed scope round trip")
    func flagAndScope() async throws {
        let temp = try TempDirectory()
        let custom = ScanScope.custom(URL(fileURLWithPath: "/Users/someone/Docs"))
        for scope in [ScanScope.quick, .full, custom] {
            await ScanStatusStore(file: file(temp)).remember(ScanMemory(
                findings: [], unattributedFromIncompleteScan: 2, unattributedScope: scope, scanDidNotFinish: true
            ))
            let loaded = try #require(await ScanStatusStore(file: file(temp)).load())
            #expect(loaded.scanDidNotFinish)
            #expect(loaded.unattributedScope == scope)
        }
        await ScanStatusStore(file: file(temp)).remember(ScanMemory(findings: []))
        let cleared = try #require(await ScanStatusStore(file: file(temp)).load())
        #expect(!cleared.scanDidNotFinish)
        #expect(cleared.unattributedScope == nil)
    }

    @Test("Home: a scan that did not finish is amber without findings and red with findings")
    func didNotFinishOnHome() async throws {
        let temp = try TempDirectory()
        let store = ScanStatusStore(file: file(temp))
        let sut = StoredScanStatusProvider(store: store, isEngineInstalled: { true })
        await store.recordScan(summary(), memory: ScanMemory(findings: []))
        await store.remember(ScanMemory(findings: [], scanDidNotFinish: true))
        var status = try #require(await sut.currentStatus())
        #expect(status.lastScanDidNotFinish)
        var report = HealthEvaluator().evaluate(snapshot: .quiet, scan: status, now: now)
        let check = try #require(report.checks.first { $0.id == .lastScan })
        #expect(check.state == .needsAttention)
        #expect(check.reason == "Last scan did not finish")
        #expect(report.checks.first { $0.id == .scannerFindings }?.state == .good)
        await store.remember(ScanMemory(findings: [finding(1)], scanDidNotFinish: true))
        status = try #require(await sut.currentStatus())
        report = HealthEvaluator().evaluate(snapshot: .quiet, scan: status, now: now)
        #expect(report.checks.first { $0.id == .scannerFindings }?.state == .problem)
        #expect(report.checks.first { $0.id == .lastScan }?.reason == "Last scan did not finish")
        await store.recordScan(summary(), memory: ScanMemory(findings: []))
        status = try #require(await sut.currentStatus())
        #expect(!status.lastScanDidNotFinish)
    }

    @Test("a damaged last-scan record with valid findings keeps the findings and says the summary is unreadable")
    func damagedSummary() async throws {
        let temp = try TempDirectory()
        let json = """
        {"version":1,"findings":[{"id":"00000000-0000-0000-0000-000000000001","path":"/Users/x/a.bin",
        "signature":"Sig","foundAt":1800000020}],
        "lastScan":{"scope":"mystery","scanned":1,"unreadable":0,"findings":1,"startedAt":1,"endedAt":2,
        "cancelled":false}}
        """
        try Data(json.utf8).write(to: file(temp))
        let loaded = try #require(await ScanStatusStore(file: file(temp)).load())
        #expect(loaded.summary == nil)
        #expect(loaded.summaryUnreadable)
        #expect(loaded.findings.count == 1)
    }

    @Test("Home: findings next to an unreadable last scan are red and never say Never scanned")
    func damagedSummaryOnHome() async throws {
        let temp = try TempDirectory()
        let json = """
        {"version":1,"findings":[{"id":"00000000-0000-0000-0000-000000000001","path":"/Users/x/a.bin",
        "signature":"Sig","foundAt":1800000020}],
        "lastScan":{"scope":"mystery","scanned":1,"unreadable":0,"findings":1,"startedAt":1,"endedAt":2,
        "cancelled":false}}
        """
        try Data(json.utf8).write(to: file(temp))
        let sut = StoredScanStatusProvider(store: ScanStatusStore(file: file(temp)), isEngineInstalled: { true })
        let status = try #require(await sut.currentStatus())
        #expect(status.unresolvedFindings == 1)
        #expect(status.lastScan == Date(timeIntervalSince1970: 1_800_000_020))
        let report = HealthEvaluator().evaluate(snapshot: .quiet, scan: status, now: now)
        #expect(report.checks.first { $0.id == .scannerFindings }?.state == .problem)
        #expect(report.checks.first { $0.id == .lastScan }?.reason != "Never scanned")
    }

    @Test("without findings an unreadable last scan is an honest Never scanned")
    func damagedSummaryWithoutFindings() async throws {
        let temp = try TempDirectory()
        let json = #"{"version":1,"findings":[],"lastScan":{"scope":"mystery"}}"#
        try Data(json.utf8).write(to: file(temp))
        let sut = StoredScanStatusProvider(store: ScanStatusStore(file: file(temp)), isEngineInstalled: { true })
        #expect(await sut.currentStatus() == ScanStatus(lastScan: nil, nextScan: nil, unresolvedFindings: 0))
    }

    @Test("Home counts the incomplete scan's unattributed detections as findings, and a completed scan clears them")
    func incompleteCountOnHome() async throws {
        let temp = try TempDirectory()
        let store = ScanStatusStore(file: file(temp))
        let sut = StoredScanStatusProvider(store: store, isEngineInstalled: { true })
        await store.recordScan(
            summary(cancelled: true, unattributed: 2),
            memory: ScanMemory(findings: [finding(1)], unattributedFromIncompleteScan: 2)
        )
        #expect(await sut.currentStatus()?.unresolvedFindings == 3)
        let report = await HealthEvaluator().evaluate(snapshot: .quiet, scan: sut.currentStatus(), now: now)
        #expect(report.checks.first { $0.id == .scannerFindings }?.state == .problem)
        await store.recordScan(summary(), memory: ScanMemory(findings: []))
        #expect(await sut.currentStatus()?.unresolvedFindings == 0)
    }

    @Test("only unattributed detections of an unfinished scan are red too")
    func onlyIncompleteUnattributed() async throws {
        let temp = try TempDirectory()
        let store = ScanStatusStore(file: file(temp))
        let sut = StoredScanStatusProvider(store: store, isEngineInstalled: { true })
        await store.remember(ScanMemory(findings: [], unattributedFromIncompleteScan: 1))
        let report = await HealthEvaluator().evaluate(snapshot: .quiet, scan: sut.currentStatus(), now: now)
        #expect(report.checks.first { $0.id == .scannerFindings }?.state == .problem)
    }
}

private extension SystemSnapshot {
    static let quiet = SystemSnapshot(
        diskTotalBytes: 460_000_000_000, diskFreeBytes: 200_000_000_000, memoryPressure: .normal,
        thermal: .nominal, cpuUsage: nil, gpuUsage: nil, temperatureCelsius: nil, battery: nil,
        newStartupItemCount: nil, osUpdateAvailable: nil
    )
}
