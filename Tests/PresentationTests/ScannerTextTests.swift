import Foundation
import MainternanceDomain
@testable import MainternancePresentation
import Testing

struct ScannerTextTests {
    private let british = Locale(identifier: "en_GB")
    private let utc = TimeZone(identifier: "UTC") ?? .gmt

    private func report(_ summary: ScanSummary) -> ScannerText.Report {
        ScannerText.report(summary, locale: british, timeZone: utc)
    }

    @Test func fixedStringsArePinned() {
        #expect(ScannerText.caption == "Detections come from ClamAV signatures and can include false positives.")
        #expect(ScannerText.quarantineExplanation
            == "The file will be moved to the app's quarantine folder. It is not deleted and you can restore it.")
        #expect(ScannerText.fullDiskAccessURL
            == "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_AllFiles")
        #expect(ScannerText.fullDiskAccessButton == "Open Full Disk Access settings")
        #expect(ScannerText.notMovedNote == "could not be moved; still in its original place")
        #expect(ScannerText.cloudAdvisory == [
            "A full scan skips your iCloud Drive (~/Library/Mobile Documents) and cloud storage",
            "(~/Library/CloudStorage) folders, so files that only live there are not checked."
        ].joined(separator: " "))
    }

    @Test func unattributedMessageIsExactAndPluralisedCorrectly() {
        #expect(ScannerText.unattributed(1)
            == "1 detection could not be attributed to a file (unusual file names). The scan is not clean.")
        #expect(ScannerText.unattributed(3)
            == "3 detections could not be attributed to a file (unusual file names). The scan is not clean.")
    }

    @Test func aCleanCompleteScanSaysWhatWasScannedAndNothingMore() {
        let result = report(makeSummary(scope: .quick, scanned: 1234))
        #expect(result.title == "No threats found")
        #expect(result.isCleanAndComplete)
        #expect(result.lines
            .contains("Quick scan: Downloads, Desktop, Applications and the Launch Agents and Launch Daemons folders."))
        #expect(result.lines.contains("1,234 files scanned."))
        #expect(result.lines.contains("Virus definitions from 14 Jan 2027."))
        #expect(!result.lines.contains { $0.contains("iCloud") })
        let words = (result.lines + [result.title]).joined(separator: " ").lowercased()
        for banned in ["safe", "protected", "your mac looks clean"] {
            #expect(!words.contains(banned), Comment(rawValue: banned))
        }
    }

    @Test func unreadableFilesMakeItPartialAndNeverClean() {
        let result = report(makeSummary(scanned: 10, unreadable: 3, denied: 3))
        #expect(result.title == "No threats found in the files that could be read")
        #expect(!result.isCleanAndComplete)
        #expect(result.lines.contains("3 files could not be read and were not scanned."))
        #expect(report(makeSummary(unreadable: 1)).lines.contains("1 file could not be read and was not scanned."))
    }

    @Test func unattributedDetectionsAreShownAndNeverClean() {
        let result = report(makeSummary(unattributed: 2))
        #expect(result.title == "Detections found")
        #expect(result.lines.contains(ScannerText.unattributed(2)))
        #expect(result.symbol == "exclamationmark.triangle.fill")
    }

    @Test func findingsTitleDoesNotClaimCleanEvenWhenEverythingWasReadable() {
        let result = report(makeSummary(findings: 2))
        #expect(result.title == "Detections found")
        #expect(!result.isCleanAndComplete)
        #expect(result.lines.contains("2 files flagged as a possible threat."))
    }

    @Test func aCancelledScanSaysOnlyPartWasChecked() {
        let result = report(makeSummary(scanned: 5, cancelled: true))
        #expect(result.title == "Scan cancelled")
        #expect(!result.isCleanAndComplete)
        #expect(result.lines.contains("You cancelled this scan, so only part of the files were checked."))
    }

    @Test func fullScansSayTheyskipCloudFoldersAndOthersDoNot() {
        #expect(report(makeSummary(scope: .full)).lines.contains(ScannerText.cloudAdvisory))
        #expect(report(makeSummary(scope: .full)).lines.contains("Full scan: your home folder and Applications."))
        #expect(!report(makeSummary(scope: .quick)).lines.contains(ScannerText.cloudAdvisory))
        #expect(report(makeSummary(scope: .custom(URL(fileURLWithPath: "/Users/x/Docs")))).lines
            .contains("Scan of /Users/x/Docs."))
    }

    @Test func missingDefinitionsDateIsSaidPlainly() {
        #expect(report(makeSummary(definitions: nil)).lines.contains("The date of the virus definitions is unknown."))
    }

    @Test func permissionExplanationNamesTheCountAndTheCause() {
        #expect(ScannerText.permissionExplanation(4, locale: british) == [
            "4 files could not be read because macOS denied access.",
            "This usually means Mainternance does not have Full Disk Access. Those files were not scanned."
        ].joined(separator: " "))
        #expect(ScannerText.permissionExplanation(1, locale: british).hasSuffix("That file was not scanned."))
    }

    @Test func engineCardsSayWhatIsTrue() {
        let idle = ScannerViewModel.RunState.idle
        #expect(ScannerText.engineCard(nil, run: idle).title == "Checking the scanning engine…")
        let missing = ScannerText.engineCard(.homebrewMissing, run: idle)
        #expect(missing.detail.contains("https://brew.sh"))
        #expect(ScannerText.engineCard(.notInstalled, run: idle).title == "Scanning engine not installed")
        #expect(ScannerText.engineCard(.ready(definitionsAge: 7200), run: idle).title == "Engine ready")
        #expect(ScannerText.engineCard(.ready(definitionsAge: 7200), run: idle).detail
            == "Virus definitions updated 2 hours ago.")
        #expect(ScannerText.engineCard(.ready(definitionsAge: nil), run: idle).detail
            == "The age of the virus definitions is unknown.")
        #expect(ScannerText.engineCard(.updateNeeded(definitionsAge: nil), run: idle)
            .title == "No virus definitions yet")
        #expect(ScannerText.engineCard(.updateNeeded(definitionsAge: 900_000), run: idle)
            .title == "Definitions out of date")
        let failed = ScannerText.engineCard(.failed(message: "boom"), run: idle)
        #expect(failed.detail == "boom")
        let installing = ScannerText.engineCard(
            .ready(definitionsAge: 1),
            run: .installing(stage: "Installing ClamAV…", progress: nil)
        )
        #expect(installing.title == "Installing ClamAV…")
    }

    @Test func ageTextIsSafeForOddValues() {
        #expect(ScannerText.ageText(60) == "less than an hour")
        #expect(ScannerText.ageText(-5) == "less than an hour")
        #expect(ScannerText.ageText(.nan) == "less than an hour")
        #expect(!ScannerText.ageText(.infinity).isEmpty)
        #expect(ScannerText.ageText(2 * 86400).contains("2"))
    }

    @Test func fileCountsUseTheRightNoun() {
        #expect(ScannerText.files(1, locale: british) == "1 file")
        #expect(ScannerText.files(0, locale: british) == "0 files")
        #expect(ScannerText.files(-3, locale: british) == "0 files")
        #expect(ScannerText.files(12345, locale: british) == "12,345 files")
    }
}

@MainActor
struct ScannerScreenStringsTests {
    @Test func visibleStringsArePinned() {
        #expect(ScannerText.installStarting == "Starting the install…")
        #expect(ScannerText.updateStarting == "Downloading definitions…")
        #expect(ScannerText.checkingFile == "Checking the file again before moving it…")
        #expect(ScannerText.quarantineTitle == "Quarantine this file?")
        #expect(ScannerText.quarantineHeading == "Quarantine")
        #expect(ScannerText.findingsHeading(3) == "Findings (3)")
        #expect(ScannerText.scanning == "Scanning…")
        #expect(ScannerText.detectedBadge == "Detected")
        #expect(ScannerText.notMovedBadge == "Not moved")
        #expect(ScannerText.quarantinedBadge == "Quarantined")
        #expect(ScannerText.detectionLine("Win.Test.EICAR_HDB-1") == "Detection: Win.Test.EICAR_HDB-1")
    }

    @Test func buttonsAndAccessibilityTextArePinned() {
        let buttons = [
            ScannerText.quickButton, ScannerText.fullButton, ScannerText.cancelButton, ScannerText.installButton,
            ScannerText.updateButton, ScannerText.checkAgainButton, ScannerText.quarantineButton,
            ScannerText.confirmButton, ScannerText.restoreButton
        ]
        #expect(buttons == [
            "Quick scan", "Full scan", "Cancel", "Install", "Update definitions", "Check again", "Quarantine…",
            "Quarantine", "Restore"
        ])
        #expect(ScannerText.cancelScanLabel == "Cancel scan")
        #expect(ScannerText.installHint == "Installs the ClamAV scanning engine with Homebrew")
        #expect(ScannerText.updateHint == "Downloads the latest virus definitions")
        #expect(ScannerText.quarantineHint == "Asks for confirmation first")
        #expect(ScannerText.restoreHint == "Puts the file back where it came from")
        #expect(ScannerText
            .fullDiskAccessHint == "Opens System Settings, where you can allow Mainternance to read all files")
        #expect(ScannerText.quarantineLabel("a.bin") == "Quarantine a.bin")
        #expect(ScannerText.restoreLabel("a.bin") == "Restore a.bin")
    }

    @Test func theInstallAndUpdateStagesAreWhatTheModelShows() async {
        let rig = ScannerRig()
        rig.engine.configure { $0.status = .notInstalled; $0.holdInstall = true }
        await rig.model.refreshStatus()
        let install = Task { await rig.model.install() }
        var calls = rig.engine.installCalls.makeAsyncIterator()
        _ = await calls.next()
        #expect(rig.model.run == .installing(stage: ScannerText.installStarting, progress: nil))
        rig.engine.finishInstall()
        await install.value
    }
}
