import MainternanceDomain
import Testing

@Suite("Uninstall outcome")
struct UninstallOutcomeTests {
    private func leftover(_ name: String, _ bytes: Int64) -> Leftover {
        Leftover(
            path: "/home/Library/Caches/\(name)", location: "Caches", match: .identifier, bytes: bytes,
            isLowerBound: false, type: .directory
        )
    }

    @Test("freed space counts the app only when it moved, plus the leftovers that moved")
    func movedBytes() {
        let moved = UninstallOutcome(
            appMoved: true, appFailure: nil, appBytes: 1000, movedLeftovers: [leftover("a", 10)],
            failedLeftovers: [LeftoverFailure(leftover: leftover("b", 500), reason: "no")], skipped: []
        )
        #expect(moved.movedBytes == 1010)
        let kept = UninstallOutcome(
            appMoved: false, appFailure: nil, appBytes: 1000, movedLeftovers: [leftover("a", 10)],
            failedLeftovers: [], skipped: []
        )
        #expect(kept.movedBytes == 10)
        let huge = UninstallOutcome(
            appMoved: true, appFailure: nil, appBytes: .max, movedLeftovers: [leftover("a", 10)],
            failedLeftovers: [], skipped: []
        )
        #expect(huge.movedBytes == .max)
    }

    @Test("the Uninstaller's own refusals read as plain sentences")
    func texts() {
        #expect(UninstallRefusal.running.text == "It is open. Quit it first.")
        #expect(UninstallRefusal.appleApp.text == "It is one of Apple's apps (bundle identifier starting com.apple.), and those are not removed.")
        #expect(UninstallRefusal.notInUninstallerFolder.text
            == "It is not in one of the folders the Uninstaller looks at.")
        #expect(UninstallRefusal.otherVolume.text == "It is on another disk, so the Uninstaller leaves it alone.")
    }
}
