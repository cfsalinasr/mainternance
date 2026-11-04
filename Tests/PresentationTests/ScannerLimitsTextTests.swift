import Foundation
import MainternanceDomain
@testable import MainternancePresentation
import Testing

/// Audit H2, M1, M4 and L3: the Scanner screen never claims more than was scanned, and shows file names cleaned.
@MainActor
struct ScannerLimitsTextTests {
    private let british = Locale(identifier: "en_GB")
    private let utc = TimeZone(identifier: "UTC") ?? .gmt

    private func report(_ summary: ScanSummary) -> ScannerText.Report {
        ScannerText.report(summary, locale: british, timeZone: utc)
    }

    // MARK: H2 too large to scan

    @Test func tooLargeFilesAreNeverShownAsAGreenNoThreatsFound() {
        let result = report(makeSummary(scanned: 10, tooLarge: 2))
        #expect(!result.isCleanAndComplete)
        #expect(result.title == "No threats found in the files that could be read")
        #expect(result.title != "No threats found")
        #expect(result.symbol != "checkmark.circle.fill")
        #expect(result.lines.contains("2 files were too large to scan and were not checked."))
        #expect(result.lines.contains("10 files scanned."))
        #expect(report(makeSummary(tooLarge: 1)).lines.contains("1 file was too large to scan and was not checked."))
        #expect(!report(makeSummary()).lines.contains { $0.contains("too large") })
    }

    @Test func aDigestSaysHowManyFilesWereTooLargeToScan() async {
        let notifications = FakeNotifications(.allowed)
        let notifier = ScanNotifier(notifications: notifications)
        notifier.update(AppPreferences.defaults)
        await notifier.scanCompleted(ScanCompletion(
            summary: makeSummary(scanned: 50, tooLarge: 2, folders: 12), scheduled: true, failed: false
        ))
        #expect(notifications.posted.first?.body
            == "Scanned 50 files. 12 folders could not be opened. 2 files were too large to scan.")
    }

    @Test func tooLargeFilesKeepAnOlderFindingThatStillExists() async {
        let rig = await ScannerRig.ready()
        await rig.scanFinding([makeFinding(1)])
        rig.engine.configure { $0.scanEvents = [.started(scope: .quick), .finished(makeSummary(tooLarge: 1))] }
        await rig.model.startScan(.quick)
        #expect(rig.model.findings == [makeFinding(1)])
    }

    // MARK: M4 unreadable folders

    @Test func unreadableFoldersAreWordedAsFoldersAndEverythingInThem() {
        let result = report(makeSummary(scanned: 10, folders: 12))
        #expect(!result.isCleanAndComplete)
        #expect(result.lines.contains("12 folders (and everything in them) could not be opened and were not scanned."))
        #expect(!result.lines.contains { $0.contains("files could not be read") })
        #expect(report(makeSummary(folders: 1)).lines
            .contains("1 folder (and everything in it) could not be opened and was not scanned."))
    }

    @Test func unreadableFoldersOfferFullDiskAccess() async {
        let rig = await ScannerRig.ready()
        rig.engine.configure { $0.scanEvents = [.started(scope: .full), .finished(makeSummary(folders: 4))] }
        await rig.model.startScan(.full)
        #expect(rig.model.needsFullDiskAccess)
        #expect(rig.model.permissionDeniedCount == 0)
        #expect(rig.model.permissionDeniedFolders == 4)
    }

    @Test func unreadableFoldersKeepAnOlderFindingThatStillExists() async {
        let rig = await ScannerRig.ready()
        await rig.scanFinding([makeFinding(1)])
        rig.engine.configure { $0.scanEvents = [.started(scope: .quick), .finished(makeSummary(folders: 1))] }
        await rig.model.startScan(.quick)
        #expect(rig.model.findings == [makeFinding(1)])
    }

    @Test func permissionExplanationNamesFoldersSeparately() {
        // A folder may also be online-only in iCloud (not downloaded), so Full Disk Access is not the only cause.
        #expect(ScannerText.permissionExplanation(0, folders: 2, locale: british) == [
            "2 folders could not be opened. Usually macOS denied access (Mainternance may need Full Disk Access),",
            "or they are stored only in iCloud and were not downloaded. Nothing in those folders was scanned."
        ].joined(separator: " "))
        #expect(ScannerText.permissionExplanation(0, folders: 1, locale: british) == [
            "1 folder could not be opened. Usually macOS denied access (Mainternance may need Full Disk Access),",
            "or it is stored only in iCloud and was not downloaded. Nothing in that folder was scanned."
        ].joined(separator: " "))
        #expect(ScannerText.permissionExplanation(3, folders: 2, locale: british) == [
            "3 files and 2 folders could not be opened. Usually macOS denied access (Mainternance may need Full",
            "Disk Access); a folder may also be stored only in iCloud and not downloaded.",
            "Those files and everything in those folders were not scanned."
        ].joined(separator: " "))
        for folders in [1, 2] {
            #expect(!ScannerText.permissionExplanation(0, folders: folders, locale: british)
                .contains("This usually means Mainternance does not have Full Disk Access"))
        }
        #expect(ScannerText.permissionExplanation(4, folders: 0, locale: british)
            == ScannerText.permissionExplanation(4, locale: british))
    }

    // MARK: M1 iCloud wording

    @Test func quickScanSaysDesktopMayHoldICloudFilesAndDoesNotClaimTheyAreSkipped() {
        let lines = report(makeSummary(scope: .quick)).lines
        #expect(lines.contains(ScannerText.quickCloudAdvisory))
        #expect(ScannerText.quickCloudAdvisory.contains("Desktop"))
        #expect(ScannerText.quickCloudAdvisory.contains("iCloud"))
        #expect(!ScannerText.quickCloudAdvisory.contains("skips"))
        #expect(!ScannerText.quickCloudAdvisory.contains("Mobile Documents"))
        // Online-only folders are counted as folders, so the note names both.
        #expect(ScannerText.quickCloudAdvisory.contains("folders that could not be opened"))
        #expect(ScannerText.quickScopeNote.hasPrefix(ScannerText.quickScope))
        #expect(ScannerText.quickScopeNote.contains(ScannerText.quickCloudAdvisory))
    }

    @Test func fullScanSaysDesktopAndDocumentsMayHoldICloudFilesThatMayBeDownloaded() {
        let advisory = ScannerText.cloudAdvisory
        #expect(report(makeSummary(scope: .full)).lines.contains(advisory))
        #expect(advisory.contains("Desktop and Documents"))
        #expect(advisory.contains("downloads one anyway"))
        #expect(advisory.contains("~/Library/Mobile Documents"))
        #expect(ScannerText.fullScopeNote == "\(ScannerText.fullScope) \(advisory)")
        #expect(!report(makeSummary(scope: .full)).lines.contains(ScannerText.quickCloudAdvisory))
    }

    @Test func aCustomScanExplainsOnlineFilesOnlyWhenSomeFilesCouldNotBeRead() {
        let folder = ScanScope.custom(URL(fileURLWithPath: "/Users/x/Documents"))
        #expect(!report(makeSummary(scope: folder)).lines.contains { $0.contains("iCloud") })
        #expect(report(makeSummary(scope: folder, unreadable: 2)).lines.contains(ScannerText.customCloudAdvisory))
        #expect(!ScannerText.customCloudAdvisory.contains("skips"))
    }

    // MARK: L3 cleaned file names

    @Test func shownPathsAndNamesAreCleanedButTheRawPathIsKept() {
        let raw = "/Users/x/Downloads/invoice\u{202E}gpj.app"
        #expect(ScannerText.shownPath(raw) == "/Users/x/Downloads/invoicegpj.app")
        #expect(ScannerText.shownName(raw) == "invoicegpj.app")
        #expect(ScannerText.shownName("/x/two\nlines.exe") == "two lines.exe")
        #expect(ScannerViewModel.name(of: raw) == "invoicegpj.app")
        #expect(ScannerText.restored(raw, signature: nil) == "Restored to /Users/x/Downloads/invoicegpj.app.")
        #expect(ScannerText.scopeLine(.custom(URL(fileURLWithPath: "/x/a\u{200B}b"))) == "Scan of /x/ab.")
    }

    @Test func quarantineMessagesUseTheCleanedName() async {
        let rig = await ScannerRig.ready()
        let raw = "/Users/someone/Downloads/invoice\u{202E}gpj.app"
        let finding = makeFinding(7, path: raw)
        await rig.scanFinding([finding])
        rig.engine.configure { $0.verifyDefault = .clean }
        rig.model.requestQuarantine(finding.id)
        await rig.model.confirmQuarantine()
        #expect(rig.model.errorMessage == ScannerText.verifyClean("invoicegpj.app"))
        #expect(rig.model.findings.first?.path == raw) // the raw path is kept for actions
    }
}
