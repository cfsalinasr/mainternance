@testable import MainternancePresentation
import Testing

struct PopoverQuitTests {
    @Test func theQuitEntryIsPinned() {
        #expect(PopoverView.quitTitle == "Quit Mainternance")
        #expect(PopoverView.quitHint == "Quits the app and stops any scan that is running")
    }
}
