import Foundation
import MainternanceDomain
import Testing

struct ScannerTypesTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let week: TimeInterval = 604_800

    private func status(installed: Bool = true, brew: Bool = true, defs: Date?) -> EngineStatus {
        EngineStatus.status(engineInstalled: installed, homebrewAvailable: brew, definitionsDate: defs, now: now)
    }

    @Test func notInstalledWithoutHomebrew() {
        #expect(status(installed: false, brew: false, defs: now) == .homebrewMissing)
    }

    @Test func notInstalledWithHomebrew() {
        #expect(status(installed: false, brew: true, defs: nil) == .notInstalled)
    }

    @Test func installedWithoutDefinitionsNeedsUpdate() {
        #expect(status(defs: nil) == .updateNeeded(definitionsAge: nil))
    }

    @Test func installedWithoutHomebrewIsStillUsable() {
        #expect(status(brew: false, defs: now.addingTimeInterval(-60)) == .ready(definitionsAge: 60))
    }

    @Test func freshDefinitionsAreReady() {
        #expect(status(defs: now) == .ready(definitionsAge: 0))
    }

    @Test func exactlySevenDaysIsReady() {
        #expect(status(defs: now.addingTimeInterval(-week)) == .ready(definitionsAge: week))
    }

    @Test func sevenDaysPlusOneSecondNeedsUpdate() {
        #expect(status(defs: now.addingTimeInterval(-week - 1)) == .updateNeeded(definitionsAge: week + 1))
    }

    @Test func futureDefinitionsDateIsAgeZeroAndReady() {
        #expect(status(defs: now.addingTimeInterval(3600)) == .ready(definitionsAge: 0))
    }

    private func summary(cancelled: Bool, end: Date) -> ScanSummary {
        ScanSummary(
            scope: .quick, scanned: 10, unreadable: 1, findings: 2,
            startedAt: end.addingTimeInterval(-5), endedAt: end, cancelled: cancelled, definitionsDate: nil
        )
    }

    @Test func completedScanCountsAsLastScan() {
        #expect(ScanSummaryRules.lastScanDate(summary: summary(cancelled: false, end: now)) == now)
    }

    @Test func cancelledScanIsNotALastScan() {
        #expect(ScanSummaryRules.lastScanDate(summary: summary(cancelled: true, end: now)) == nil)
    }

    @Test func scanStatusMapping() {
        let done = ScanSummaryRules.scanStatus(from: summary(cancelled: false, end: now), unresolvedFindings: 3)
        #expect(done == ScanStatus(lastScan: now, nextScan: nil, unresolvedFindings: 3))
        let cancelled = ScanSummaryRules.scanStatus(from: summary(cancelled: true, end: now), unresolvedFindings: 2)
        #expect(cancelled == ScanStatus(lastScan: nil, nextScan: nil, unresolvedFindings: 2))
        let never = ScanSummaryRules.scanStatus(from: nil, unresolvedFindings: 0)
        #expect(never == ScanStatus(lastScan: nil, nextScan: nil, unresolvedFindings: 0))
    }

    @Test func quarantineRecordCodableRoundTrip() throws {
        let id = try #require(UUID(uuidString: "6F9619FF-8B86-D011-B42D-00C04FC964FF"))
        let record = QuarantineRecord(
            id: id,
            originalPath: "/Users/x/Downloads/eicar.com", quarantinedAt: Date(timeIntervalSince1970: 1_700_000_000),
            signature: "Eicar-Test-Signature", sha256: String(repeating: "ab", count: 32), size: 9_000_000_000
        )
        // Fixed strategy: dates as seconds since 1970 (no locale or time zone dependence).
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let data = try encoder.encode(record)
        let json = try #require(String(data: data, encoding: .utf8))
        #expect(json.contains("6F9619FF-8B86-D011-B42D-00C04FC964FF"))
        #expect(json.contains("9000000000"))
        let decoded = try decoder.decode(QuarantineRecord.self, from: data)
        #expect(decoded == record)
        #expect(decoded.size == 9_000_000_000)
    }

    private func requireSendable(_: (some Sendable).Type) {}

    @Test func typesAreSendable() {
        requireSendable(EngineStatus.self)
        requireSendable(ScanScope.self)
        requireSendable(ScanFinding.self)
        requireSendable(ScanEvent.self)
        requireSendable(ScanSummary.self)
        requireSendable(InstallEvent.self)
        requireSendable(QuarantineRecord.self)
        requireSendable(QuarantineError.self)
        requireSendable((any ScannerEngine).self)
        requireSendable((any QuarantineStoring).self)
    }

    @Test func findingIdentityAndScopeEquality() {
        let url = URL(fileURLWithPath: "/tmp/a")
        #expect(ScanScope.custom(url) == .custom(url))
        #expect(ScanScope.custom(url) != .quick)
        let finding = ScanFinding(id: UUID(), path: "/a", signature: "S", foundAt: now)
        #expect(finding.id == finding.id)
    }
}
