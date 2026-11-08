import Darwin
import Foundation
@testable import MainternanceData
import MainternanceDomain
import Synchronization
import Testing

/// Policy values seen or written, in order.
private final class PolicyLog: Sendable {
    private let values = Mutex<[Int32]>([])

    func add(_ value: Int32) {
        values.withLock { $0.append(value) }
    }

    var all: [Int32] {
        values.withLock { $0 }
    }
}

/// Audit M1: clamscan must not make iCloud download files that are stored only online. New processes inherit the
/// materialization policy of the app at the moment they start, so the policy is OFF exactly while clamscan is
/// started, and put back afterwards so the rest of the app is unchanged.
@Suite("Scanner never asks for iCloud downloads")
struct ScanMaterializationTests {
    private static func rawPolicy() -> Int32 {
        getiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_PROCESS)
    }

    /// A runner that records the app's materialization policy at the moment the child would be started.
    private static func recordingRunner(
        _ seen: PolicyLog, lines: @escaping @Sendable (RunCall) -> [ProcessLine]
    ) -> FakeRunner {
        FakeRunner { call in
            // The policy lock is already held by the scanner here: read the raw value, never through the lock.
            seen.add(rawPolicy())
            return RunningProcess.finished(lines: lines(call), status: 0)
        }
    }

    @Test("clamscan starts with downloads of online-only files turned off, and the app's policy is put back")
    func scanStartsWithMaterializationOff() async throws {
        let seen = PolicyLog()
        let before = DatalessPolicy.currentProcessPolicy()
        let fixture = try ScannerFixture(runner: Self.recordingRunner(seen) { _ in [] })
        _ = await fixture.run()
        #expect(seen.all == [IOPOL_MATERIALIZE_DATALESS_FILES_OFF])
        #expect(DatalessPolicy.currentProcessPolicy() == before)
    }

    @Test("the re-check before quarantine also starts with downloads turned off")
    func verifyStartsWithMaterializationOff() async throws {
        let seen = PolicyLog()
        let temp = try TempDirectory()
        let path = temp.url.appendingPathComponent("target").appendingPathComponent("f.exe").path
        let runner = Self.recordingRunner(seen) { _ in [.stdout("\(path): OK")] }
        let fixture = try ScannerFixture(temp: temp, runner: runner)
        try Data("x".utf8).write(to: URL(fileURLWithPath: path))
        #expect(await fixture.scanner.verifyFinding(path: path) == .clean)
        #expect(seen.all == [IOPOL_MATERIALIZE_DATALESS_FILES_OFF])
    }

    @Test("an earlier policy is put back exactly as it was")
    func restoresAnEarlierPolicy() {
        let sets = PolicyLog()
        let system = DatalessPolicy.System(
            get: { IOPOL_MATERIALIZE_DATALESS_FILES_ON },
            set: { value in
                sets.add(value)
                return 0
            }
        )
        let result = DatalessPolicy.withMaterializationOff(system) { "started" }
        #expect(result == "started")
        #expect(sets.all == [IOPOL_MATERIALIZE_DATALESS_FILES_OFF, IOPOL_MATERIALIZE_DATALESS_FILES_ON])
    }

    @Test("when the policy cannot be read the default is put back; when it cannot be set the child still starts")
    func failuresStillStartTheChild() {
        let sets = PolicyLog()
        let unreadable = DatalessPolicy.System(get: { -1 }, set: { value in
            sets.add(value)
            return 0
        })
        #expect(DatalessPolicy.withMaterializationOff(unreadable) { 7 } == 7)
        #expect(sets.all == [IOPOL_MATERIALIZE_DATALESS_FILES_OFF, IOPOL_MATERIALIZE_DATALESS_FILES_DEFAULT])
        let refusedSets = PolicyLog()
        let refused = DatalessPolicy.System(get: { IOPOL_MATERIALIZE_DATALESS_FILES_DEFAULT }, set: { value in
            refusedSets.add(value)
            return -1
        })
        #expect(DatalessPolicy.withMaterializationOff(refused) { 8 } == 8)
        // Setting OFF failed, so nothing changed and nothing is undone.
        #expect(refusedSets.all == [IOPOL_MATERIALIZE_DATALESS_FILES_OFF])
    }
}
