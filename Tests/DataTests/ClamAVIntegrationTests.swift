import Foundation
@testable import MainternanceData
import MainternanceDomain
import Testing

/// Opt-in: runs the REAL `clamscan` against a harmless EICAR test file in a temp folder. Skipped (with the reason
/// in the trait) unless `clamscan` is installed AND `MAINTERNANCE_CLAMAV_DB` names a ClamAV database folder, for
/// example `MAINTERNANCE_CLAMAV_DB="$HOME/Library/Application Support/Mainternance/ClamAV/database" scripts/test.sh`.
/// The test never reads the real Application Support on its own: it uses a temp support folder whose database
/// folder is a symlink to the one named, and only reads it.
@Suite("ClamAV integration (real clamscan)")
struct ClamAVIntegrationTests {
    private static let locator = ToolLocator()

    private static var databaseSource: URL? {
        guard let value = ProcessInfo.processInfo.environment["MAINTERNANCE_CLAMAV_DB"], !value.isEmpty else {
            return nil
        }
        return URL(fileURLWithPath: value, isDirectory: true)
    }

    static var available: Bool {
        var isFolder: ObjCBool = false
        guard locator.path(for: "clamscan") != nil, let source = databaseSource,
              FileManager.default.fileExists(atPath: source.path, isDirectory: &isFolder) else { return false }
        return isFolder.boolValue
    }

    /// A temp support folder whose `ClamAV/database` points at the opted-in database.
    private static func tempPaths(in temp: TempDirectory) throws -> ClamAVPaths {
        let paths = ClamAVPaths(supportDirectory: temp.url.appendingPathComponent("Support", isDirectory: true))
        try FileManager.default.createDirectory(at: paths.root, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: paths.databaseDirectory, withDestinationURL: #require(databaseSource)
        )
        return paths
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
        .enabled(if: ClamAVIntegrationTests.available, "needs clamscan and MAINTERNANCE_CLAMAV_DB")
    )
    func realEicar() async throws {
        let temp = try TempDirectory()
        let paths = try Self.tempPaths(in: temp)
        #expect(DefinitionsStore(paths: paths).definitionsDate() != nil)
        let folder = temp.url.appendingPathComponent("scan me", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(Self.eicar.utf8).write(to: folder.appendingPathComponent("test file.com"))
        try Data("harmless".utf8).write(to: folder.appendingPathComponent("clean.txt"))

        let runner = SystemProcessRunner()
        let installer = ClamAVInstaller(locator: Self.locator, runner: runner, paths: paths)
        let scanner = ClamAVScanner(
            locator: Self.locator, runner: runner, paths: paths,
            definitions: DefinitionsStore(paths: paths), installer: installer
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
