import Foundation
@testable import MainternanceData
import MainternanceDomain
import Testing

/// Opt-in: runs the REAL `clamscan` against a harmless EICAR test file in a temp folder. Skipped (with the reason
/// in the trait) unless `clamscan` is installed AND the app-owned definitions database exists on this Mac.
@Suite("ClamAV integration (real clamscan)")
struct ClamAVIntegrationTests {
    private static let locator = ToolLocator()
    private static let paths = ClamAVPaths()

    static var available: Bool {
        locator.path(for: "clamscan") != nil && DefinitionsStore(paths: paths).definitionsDate() != nil
    }

    /// The EICAR antivirus test string, built from two halves so this repository never contains a file that
    /// antivirus tools flag. It is written only inside a temp directory that is removed afterwards.
    private static var eicar: String {
        let first = "X5O!P%@AP[4\\PZX54(P^)7CC)7}$EICAR-STANDARD-"
        let second = "ANTIVIRUS-TEST-FILE!$H+H*"
        return first + second
    }

    @Test(
        "scans a temp folder holding the EICAR test file and reports exactly one Eicar finding",
        .enabled(if: ClamAVIntegrationTests.available, "needs clamscan and a definitions database")
    )
    func realEicar() async throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("mainternance-eicar-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data(Self.eicar.utf8).write(to: folder.appendingPathComponent("test file.com"))
        try Data("harmless".utf8).write(to: folder.appendingPathComponent("clean.txt"))

        let runner = SystemProcessRunner()
        let installer = ClamAVInstaller(locator: Self.locator, runner: runner, paths: Self.paths)
        let scanner = ClamAVScanner(
            locator: Self.locator, runner: runner, paths: Self.paths,
            definitions: DefinitionsStore(paths: Self.paths), installer: installer
        )
        var events: [ScanEvent] = []
        for await event in scanner.scan(.custom(folder)) {
            events.append(event)
        }
        let finding = try #require(events.findings.first)
        #expect(events.findings.count == 1)
        #expect(finding.signature.lowercased().contains("eicar"))
        #expect(finding.path.hasSuffix("/test file.com"))
        #expect(events.summary?.findings == 1)
        #expect(events.failure == nil)
    }
}
