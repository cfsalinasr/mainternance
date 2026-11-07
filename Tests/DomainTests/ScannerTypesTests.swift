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

    /// Ages are `Double`s from date arithmetic, so they are compared with a tolerance.
    private func isReady(_ status: EngineStatus, age expected: TimeInterval) -> Bool {
        guard case let .ready(age?) = status else { return false }
        return abs(age - expected) < 1e-6
    }

    private func needsUpdate(_ status: EngineStatus, age expected: TimeInterval) -> Bool {
        guard case let .updateNeeded(age?) = status else { return false }
        return abs(age - expected) < 1e-6
    }

    @Test func installedWithoutHomebrewIsStillUsable() {
        #expect(isReady(status(brew: false, defs: now.addingTimeInterval(-60)), age: 60))
    }

    @Test func freshDefinitionsAreReady() {
        #expect(isReady(status(defs: now), age: 0))
    }

    @Test func exactlySevenDaysIsReady() {
        #expect(isReady(status(defs: now.addingTimeInterval(-week)), age: week))
    }

    @Test func sevenDaysPlusOneSecondNeedsUpdate() {
        #expect(needsUpdate(status(defs: now.addingTimeInterval(-week - 1)), age: week + 1))
    }

    @Test func futureDefinitionsDateIsAgeZeroAndReady() {
        #expect(isReady(status(defs: now.addingTimeInterval(3600)), age: 0))
    }

    private func summary(cancelled: Bool, end: Date) -> ScanSummary {
        ScanSummary(
            scope: .quick, scanned: 10, unreadable: 1, findings: 2,
            startedAt: end.addingTimeInterval(-5), endedAt: end, cancelled: cancelled, definitionsDate: nil
        )
    }

    @Test func permissionDeniedDefaultsToZeroAndIsBoundedByUnreadable() {
        func make(unreadable: Int, denied: Int?) -> ScanSummary {
            if let denied {
                return ScanSummary(
                    scope: .quick, scanned: 1, unreadable: unreadable, findings: 0,
                    startedAt: now, endedAt: now, cancelled: false, definitionsDate: nil, permissionDenied: denied
                )
            }
            return ScanSummary(
                scope: .quick, scanned: 1, unreadable: unreadable, findings: 0,
                startedAt: now, endedAt: now, cancelled: false, definitionsDate: nil
            )
        }
        #expect(make(unreadable: 4, denied: nil).permissionDenied == 0)
        #expect(make(unreadable: 4, denied: 3).permissionDenied == 3)
        #expect(make(unreadable: 2, denied: 9).permissionDenied == 2)
        #expect(make(unreadable: 2, denied: -1).permissionDenied == 0)
    }

    @Test func cleanAndCompleteTruthTable() {
        func make(
            findings: Int = 0, unattributed: Int = 0, unreadable: Int = 0, cancelled: Bool = false
        ) -> ScanSummary {
            ScanSummary(
                scope: .quick, scanned: 5, unreadable: unreadable, findings: findings, startedAt: now, endedAt: now,
                cancelled: cancelled, definitionsDate: nil, unattributedDetections: unattributed
            )
        }
        #expect(make().isClean && make().isComplete)
        #expect(!make(findings: 1).isClean)
        #expect(!make(unattributed: 1).isClean)
        #expect(!make(cancelled: true).isClean && !make(cancelled: true).isComplete)
        #expect(make(unreadable: 2).isClean && !make(unreadable: 2).isComplete)
        #expect(make(unattributed: -3).unattributedDetections == 0)
        #expect(make(unattributed: 2).isComplete)
    }

    /// Audit H2 and M4: files skipped for clamscan's limits and folders that could not be opened were not scanned.
    @Test func tooLargeFilesAndUnreadableFoldersMakeAScanPartialButNotUnclean() {
        func make(tooLarge: Int = 0, folders: Int = 0) -> ScanSummary {
            ScanSummary(
                scope: .quick, scanned: 5, unreadable: 0, findings: 0, startedAt: now, endedAt: now,
                cancelled: false, definitionsDate: nil, tooLarge: tooLarge, unreadableFolders: folders
            )
        }
        #expect(make().isComplete)
        #expect(make(tooLarge: 1).isClean && !make(tooLarge: 1).isComplete)
        #expect(make(folders: 1).isClean && !make(folders: 1).isComplete)
        #expect(make(tooLarge: -2).tooLarge == 0)
        #expect(make(folders: -2).unreadableFolders == 0)
    }

    @Test func verifyResultsCompareByValue() {
        #expect(VerifyResult.confirmed(signature: "A") == .confirmed(signature: "A"))
        #expect(VerifyResult.confirmed(signature: "A") != .confirmed(signature: "B"))
        #expect(VerifyResult.clean != .failed(message: "x"))
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

    @Test func scanStatusAddsUnattributedDetections() {
        let unattributed = ScanSummary(
            scope: .quick, scanned: 1, unreadable: 0, findings: 0,
            startedAt: now, endedAt: now, cancelled: false, definitionsDate: nil, unattributedDetections: 2
        )
        #expect(ScanSummaryRules.scanStatus(from: unattributed, unresolvedFindings: 3).unresolvedFindings == 5)
        #expect(ScanSummaryRules.scanStatus(from: unattributed, unresolvedFindings: -4).unresolvedFindings == 2)
        #expect(ScanSummaryRules.scanStatus(from: summary(cancelled: false, end: now), unresolvedFindings: 1)
            .unresolvedFindings == 1)
        #expect(ScanSummaryRules.scanStatus(from: nil, unresolvedFindings: 0).unresolvedFindings == 0)
    }

    @Test func quarantineRecordCodableRoundTrip() throws {
        let id = try #require(UUID(uuidString: "6F9619FF-8B86-D011-B42D-00C04FC964FF"))
        let record = QuarantineRecord(
            id: id,
            originalPath: "/Users/x/Downloads/eicar.com", quarantinedAt: Date(timeIntervalSince1970: 1_700_000_000),
            signature: "Eicar-Test-Signature", sha256: String(repeating: "ab", count: 32), size: 9_000_000_000,
            originalPermissions: 0o755
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
