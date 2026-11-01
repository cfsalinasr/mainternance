import Foundation
@testable import MainternanceData
import MainternanceDomain
import Testing

@Suite("Scan status store")
struct ScanStatusStoreTests {
    private func summary(
        scope: ScanScope = .quick, scanned: Int = 120, unreadable: Int = 0, denied: Int = 0, findings: Int = 0,
        unattributed: Int = 0, cancelled: Bool = false, ended: TimeInterval = 1_800_000_100,
        definitions: Date? = Date(timeIntervalSince1970: 1_799_990_000)
    ) -> ScanSummary {
        ScanSummary(
            scope: scope, scanned: scanned, unreadable: unreadable, findings: findings,
            startedAt: Date(timeIntervalSince1970: 1_800_000_000), endedAt: Date(timeIntervalSince1970: ended),
            cancelled: cancelled, definitionsDate: definitions, permissionDenied: denied,
            unattributedDetections: unattributed
        )
    }

    private func store(_ temp: TempDirectory) -> ScanStatusStore {
        ScanStatusStore(file: temp.url.appendingPathComponent("support/scan-status.json"))
    }

    private func finding(_ index: Int) -> ScanFinding {
        ScanFinding(
            id: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", index)) ?? UUID(),
            path: "/Users/someone/Downloads/file \(index).bin", signature: "Win.Test.EICAR_HDB-\(index)",
            foundAt: Date(timeIntervalSince1970: 1_800_000_050)
        )
    }

    @Test("nothing stored yet reads as nil, not as an empty status")
    func missing() async throws {
        let temp = try TempDirectory()
        #expect(await store(temp).load() == nil)
    }

    @Test("a scan and its findings survive a round trip through a new store instance")
    func roundTrip() async throws {
        let temp = try TempDirectory()
        let written = summary(
            scope: .full, scanned: 5000, unreadable: 7, denied: 4, findings: 2, unattributed: 3
        )
        let found = [finding(1), finding(2)]
        await store(temp).recordScan(written, memory: ScanMemory(findings: found))
        let loaded = try #require(await store(temp).load())
        #expect(loaded.summary == written)
        #expect(loaded.findings == found)
    }

    @Test("every scope round trips, a custom folder included, and a missing definitions date stays nil")
    func scopes() async throws {
        let temp = try TempDirectory()
        let custom = ScanScope.custom(URL(fileURLWithPath: "/Users/someone/Some Folder"))
        for scope in [ScanScope.quick, .full, custom] {
            let sut = store(temp)
            let written = summary(scope: scope, definitions: nil)
            await sut.recordScan(written, memory: ScanMemory(findings: []))
            #expect(await sut.load()?.summary == written)
        }
    }

    @Test("a cancelled scan never becomes the last scan, but the findings it reported are kept")
    func cancelledIsIgnored() async throws {
        let temp = try TempDirectory()
        let sut = store(temp)
        let completed = summary(ended: 1_800_000_500)
        await sut.recordScan(completed, memory: ScanMemory(findings: []))
        await sut.recordScan(
            summary(cancelled: true, ended: 1_800_009_999),
            memory: ScanMemory(findings: [finding(1), finding(2)])
        )
        let loaded = try #require(await sut.load())
        #expect(loaded.summary == completed)
        #expect(loaded.findings == [finding(1), finding(2)])
    }

    @Test("a cancelled first scan leaves no last scan at all")
    func cancelledFirstScan() async throws {
        let temp = try TempDirectory()
        let sut = store(temp)
        await sut.recordScan(summary(cancelled: true), memory: ScanMemory(findings: [finding(1)]))
        let loaded = try #require(await sut.load())
        #expect(loaded.summary == nil)
        #expect(loaded.findings == [finding(1)])
    }

    @Test("updating the findings keeps the last scan")
    func updateFindings() async throws {
        let temp = try TempDirectory()
        let sut = store(temp)
        let completed = summary(findings: 3)
        await sut.recordScan(completed, memory: ScanMemory(findings: [finding(1), finding(2), finding(3)]))
        await sut.remember(ScanMemory(findings: [finding(1), finding(3)]))
        #expect(await sut.load()?.findings == [finding(1), finding(3)])
        #expect(await sut.load()?.summary == completed)
        await sut.remember(ScanMemory(findings: []))
        #expect(await sut.load()?.findings == [])
        #expect(await sut.load()?.summary == completed)
    }

    @Test("updating before any scan stores the findings with no last scan")
    func updateWithoutScan() async throws {
        let temp = try TempDirectory()
        let sut = store(temp)
        await sut.remember(ScanMemory(findings: [finding(4)]))
        let loaded = try #require(await sut.load())
        #expect(loaded.summary == nil)
        #expect(loaded.findings == [finding(4)])
    }

    @Test("a corrupt or unknown file reads as nil and is replaced by the next write")
    func corrupt() async throws {
        let temp = try TempDirectory()
        let file = temp.url.appendingPathComponent("support/scan-status.json")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let texts = [
            "", "not json", "{\"version\": 99, \"findings\": []}", "[1,2,3]", "{}",
            "{\"version\":1,\"findings\":[{\"id\":\"nope\",\"path\":\"/a\",\"signature\":\"s\",\"foundAt\":1}]}",
            "{\"version\":1,\"findings\":[{\"id\":\"00000000-0000-0000-0000-000000000001\",\"path\":\"rel\","
                + "\"signature\":\"s\",\"foundAt\":1}]}"
        ]
        for text in texts {
            try Data(text.utf8).write(to: file)
            let sut = ScanStatusStore(file: file)
            #expect(await sut.load() == nil, "\(text)")
        }
        let sut = ScanStatusStore(file: file)
        await sut.remember(ScanMemory(findings: [finding(1)]))
        #expect(await sut.load()?.findings == [finding(1)])
    }

    @Test("the file format is pinned: this exact JSON decodes to this scan")
    func pinnedFormat() async throws {
        let temp = try TempDirectory()
        let file = temp.url.appendingPathComponent("scan-status.json")
        let json = """
        {"version":1,"findings":[{"id":"00000000-0000-0000-0000-000000000007","path":"/Users/x/a.bin",
        "signature":"Win.Test.EICAR_HDB-1","foundAt":1800000020}],
        "lastScan":{"scope":"custom","customPath":"/Users/x/Folder",
        "scanned":10,"unreadable":3,"permissionDenied":2,"findings":1,"startedAt":1800000000,
        "endedAt":1800000060.5,"cancelled":false,"definitionsDate":1799990000,"unattributedDetections":4}}
        """
        try Data(json.utf8).write(to: file)
        let loaded = try #require(await ScanStatusStore(file: file).load())
        #expect(try loaded.findings == [ScanFinding(
            id: #require(UUID(uuidString: "00000000-0000-0000-0000-000000000007")), path: "/Users/x/a.bin",
            signature: "Win.Test.EICAR_HDB-1", foundAt: Date(timeIntervalSince1970: 1_800_000_020)
        )])
        #expect(loaded.summary == ScanSummary(
            scope: .custom(URL(fileURLWithPath: "/Users/x/Folder")), scanned: 10, unreadable: 3, findings: 1,
            startedAt: Date(timeIntervalSince1970: 1_800_000_000),
            endedAt: Date(timeIntervalSince1970: 1_800_000_060.5), cancelled: false,
            definitionsDate: Date(timeIntervalSince1970: 1_799_990_000), permissionDenied: 2,
            unattributedDetections: 4
        ))
    }

    @Test("a scan written before unattributed detections existed still loads, with 0")
    func olderFileWithoutUnattributed() async throws {
        let temp = try TempDirectory()
        let file = temp.url.appendingPathComponent("scan-status.json")
        let json = """
        {"version":1,"findings":[],"lastScan":{"scope":"quick","scanned":1,"unreadable":0,
        "permissionDenied":0,"findings":0,"startedAt":1800000000,"endedAt":1800000001,"cancelled":false}}
        """
        try Data(json.utf8).write(to: file)
        let loaded = try #require(await ScanStatusStore(file: file).load())
        #expect(loaded.summary?.unattributedDetections == 0)
        #expect(loaded.summary?.definitionsDate == nil)
    }

    @Test("the file is private to the user and written below a folder that is created on demand")
    func filePermissions() async throws {
        let temp = try TempDirectory()
        await store(temp).remember(ScanMemory(findings: [finding(1)]))
        let file = temp.url.appendingPathComponent("support/scan-status.json")
        #expect(permissions(file) == 0o600)
        #expect(permissions(file.deletingLastPathComponent()) == 0o700)
    }
}

private let stubSnapshot = SystemSnapshot(
    diskTotalBytes: 460_000_000_000, diskFreeBytes: 200_000_000_000, memoryPressure: .normal,
    thermal: .nominal, cpuUsage: nil, gpuUsage: nil, temperatureCelsius: nil, battery: nil,
    newStartupItemCount: nil, osUpdateAvailable: nil
)

private struct StubSnapshots: SystemSnapshotProviding {
    func currentSnapshot() async -> SystemSnapshot {
        stubSnapshot
    }
}

private struct NoActions: SuggestedActionsProviding {
    func suggestedActions() async -> [SuggestedAction] {
        []
    }
}

@Suite("Stored scan status provider")
struct StoredScanStatusProviderTests {
    private let now = Date(timeIntervalSince1970: 1_800_100_000)

    private func completed(findings: Int = 0, unattributed: Int = 0, cancelled: Bool = false) -> ScanSummary {
        ScanSummary(
            scope: .quick, scanned: 10, unreadable: 0, findings: findings,
            startedAt: now.addingTimeInterval(-70), endedAt: now.addingTimeInterval(-60), cancelled: cancelled,
            definitionsDate: nil, unattributedDetections: unattributed
        )
    }

    private func provider(
        installed: Bool, _ temp: TempDirectory
    ) -> (StoredScanStatusProvider, ScanStatusStore) {
        let store = ScanStatusStore(file: temp.url.appendingPathComponent("scan-status.json"))
        return (StoredScanStatusProvider(store: store, isEngineInstalled: { installed }), store)
    }

    private func finding(_ index: Int) -> ScanFinding {
        ScanFinding(
            id: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", index)) ?? UUID(),
            path: "/Users/someone/Downloads/file \(index).bin", signature: "Win.Test.EICAR_HDB-\(index)",
            foundAt: now
        )
    }

    private func report(for status: ScanStatus?) -> HealthReport {
        HealthEvaluator().evaluate(snapshot: stubSnapshot, scan: status, now: now)
    }

    @Test("no engine installed: the provider returns nil, so health has no scan checks at all")
    func notInstalled() async throws {
        let temp = try TempDirectory()
        let (sut, store) = provider(installed: false, temp)
        // Even leftovers from an earlier install must not turn into a status while there is no engine.
        await store.recordScan(completed(findings: 2), memory: ScanMemory(findings: [finding(1), finding(2)]))
        let status = await sut.currentStatus()
        #expect(status == nil)
        let ids = report(for: status).checks.map(\.id)
        #expect(!ids.contains(.lastScan))
        #expect(!ids.contains(.scannerFindings))
        // Through the real use case: nil reaches the evaluator and the overview carries no scan status.
        let overview = await LoadOverview(snapshots: StubSnapshots(), scans: sut, actions: NoActions(), now: { now })()
        #expect(overview.scan == nil)
        #expect(!overview.report.checks.contains { $0.id == .lastScan || $0.id == .scannerFindings })
    }

    @Test("installed and never scanned: amber Never scanned")
    func neverScanned() async throws {
        let temp = try TempDirectory()
        let (sut, _) = provider(installed: true, temp)
        let status = await sut.currentStatus()
        #expect(status == ScanStatus(lastScan: nil, nextScan: nil, unresolvedFindings: 0))
        let check = try #require(report(for: status).checks.first { $0.id == .lastScan })
        #expect(check.state == .needsAttention)
        #expect(check.reason == "Never scanned")
    }

    @Test("a completed scan gives its end date, and nextScan stays nil")
    func completedScan() async throws {
        let temp = try TempDirectory()
        let (sut, store) = provider(installed: true, temp)
        let summary = completed()
        await store.recordScan(summary, memory: ScanMemory(findings: []))
        let status = try #require(await sut.currentStatus())
        #expect(status.lastScan == summary.endedAt)
        #expect(status.nextScan == nil)
        #expect(status.unresolvedFindings == 0)
        #expect(report(for: status).checks.first { $0.id == .lastScan }?.state == .good)
    }

    @Test("a cancelled scan is not a last scan")
    func cancelled() async throws {
        let temp = try TempDirectory()
        let (sut, store) = provider(installed: true, temp)
        await store.recordScan(completed(cancelled: true), memory: ScanMemory(findings: []))
        #expect(await sut.currentStatus()?.lastScan == nil)
    }

    @Test("findings make Home red, unattributed detections count as findings, and quarantining lowers the count")
    func findings() async throws {
        let temp = try TempDirectory()
        let (sut, store) = provider(installed: true, temp)
        await store.recordScan(
            completed(findings: 2, unattributed: 1),
            memory: ScanMemory(findings: [finding(1), finding(2)])
        )
        var status = try #require(await sut.currentStatus())
        #expect(status.unresolvedFindings == 3)
        #expect(report(for: status).checks.first { $0.id == .scannerFindings }?.state == .problem)
        await store.remember(ScanMemory(findings: [finding(1)]))
        status = try #require(await sut.currentStatus())
        #expect(status.unresolvedFindings == 2)
        await store.remember(ScanMemory(findings: []))
        status = try #require(await sut.currentStatus())
        #expect(status.unresolvedFindings == 1) // The unattributed detection is still unresolved.
    }

    @Test("only unattributed detections: still red")
    func onlyUnattributed() async throws {
        let temp = try TempDirectory()
        let (sut, store) = provider(installed: true, temp)
        await store.recordScan(completed(findings: 0, unattributed: 2), memory: ScanMemory(findings: []))
        let status = await sut.currentStatus()
        #expect(report(for: status).checks.first { $0.id == .scannerFindings }?.state == .problem)
    }
}
