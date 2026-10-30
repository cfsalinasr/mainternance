import Foundation
@testable import MainternanceData
import Testing

@Suite("freshclam config and progress parsing")
struct FreshclamParsingTests {
    private func parse(_ line: String) -> Double? {
        ClamAVInstaller.parseFreshclamProgress(line)
    }

    @Test("progress forms from freshclam")
    func progressTable() throws {
        let full = try #require(parse("Time: 4.3s, ETA: 0.0s [=========================>] 62.58MiB/62.58MiB"))
        #expect(abs(full - 1) < 1e-9)
        let half = try #require(parse("Time: 1.0s, ETA: 1.0s [============>             ] 1.00MiB/2.00MiB"))
        #expect(abs(half - 0.5) < 1e-9)
        let mixed = try #require(parse("[===>] 512KiB/1MiB"))
        #expect(abs(mixed - 0.5) < 1e-9)
        let percent = try #require(parse("Downloading daily-27000 [ 62%]"))
        #expect(abs(percent - 0.62) < 1e-9)
        let fractional = try #require(parse("progress 12.5%"))
        #expect(abs(fractional - 0.125) < 1e-9)
        let redrawn = try #require(parse("Time: 0.1s [>] 1MiB/4MiB\rTime: 0.2s [=>] 2MiB/4MiB"))
        #expect(abs(redrawn - 0.5) < 1e-9)
    }

    @Test("clamped to 0...1")
    func clamped() throws {
        #expect(try #require(parse("150%")) == 1)
        #expect(try #require(parse("0%")) == 0)
        #expect(try #require(parse("[=] 9MiB/1MiB")) == 1)
    }

    @Test("lines without progress are nil", arguments: [
        "", "   ", "daily.cvd database available for update (local version: 1, remote version: 2)",
        "ClamAV update process started at Thu Oct 29 10:00:00 2026", "daily.cvd updated (version: 27000)",
        "50 percent", "/", "%", "MiB/MiB", "1MiB/0MiB", "-5%", "-1MiB/2MiB", "[===>]", "ERROR: Can't connect"
    ])
    func garbage(line: String) {
        #expect(parse(line) == nil)
    }

    @Test("huge and odd numbers never crash")
    func huge() {
        let digits = String(repeating: "9", count: 400)
        #expect(parse("\(digits)%") == nil)
        #expect(parse("\(digits)MiB/\(digits)MiB") == nil)
        #expect(parse("99999999999999999999%") == 1)
        #expect(parse("1MiB/99999999999999999999999TiB") != nil)
        #expect(parse(String(repeating: "\r", count: 10)) == nil)
        #expect(parse("\u{0}%\u{FFFD}1/2") == nil)
    }

    @Test("config has the database and the mirror, no Example and no Homebrew paths")
    func configContent() {
        let url = URL(fileURLWithPath: "/Users/me/Library/Application Support/Mainternance/ClamAV/database")
        let config = ClamAVInstaller.freshclamConfig(databaseDirectory: url)
        let lines = config.split(separator: "\n").map(String.init)
        #expect(lines.contains("DatabaseDirectory /Users/me/Library/Application Support/Mainternance/ClamAV/database"))
        #expect(lines.contains("DatabaseMirror database.clamav.net"))
        #expect(!config.contains("Example"))
        #expect(!config.contains("/opt/homebrew"))
        #expect(!config.contains("\""))
        #expect(config.hasSuffix("\n"))
    }

    @Test("config values with line breaks are unsafe")
    func unsafeValues() {
        #expect(ClamAVInstaller.isSafeConfigValue("/a b/c"))
        #expect(!ClamAVInstaller.isSafeConfigValue("/a\nExample"))
        #expect(!ClamAVInstaller.isSafeConfigValue("/a\rb"))
        #expect(!ClamAVInstaller.isSafeConfigValue("/a\0b"))
    }

    @Test("brew stage mapping")
    func stages() {
        #expect(ClamAVInstaller.brewStage(for: "==> Downloading https://ghcr.io/x") == "Downloading ClamAV…")
        #expect(ClamAVInstaller.brewStage(for: "==> Pouring clamav--1.5.4.arm64.bottle.tar.gz") == "Installing ClamAV…")
        #expect(ClamAVInstaller.brewStage(for: "==> Summary") == "Finishing…")
        #expect(ClamAVInstaller.brewStage(for: "==> Caveats") == nil)
        #expect(ClamAVInstaller.brewStage(for: "Downloading") == nil)
        #expect(ClamAVInstaller.brewStage(for: "") == nil)
    }

    @Test("sanitizing removes control characters and bounds the length")
    func sanitizing() {
        let clean = ClamAVInstaller.sanitized("\u{1B}[31mError:\u{7} boom\t\u{0}here\u{1B}[0m")
        #expect(!clean.unicodeScalars.contains { $0.properties.generalCategory == .control })
        #expect(clean.contains("boom"))
        let long = ClamAVInstaller.sanitized(String(repeating: "x", count: 5000))
        #expect(long.count == ClamAVInstaller.maxMessageLength + 1)
    }
}
