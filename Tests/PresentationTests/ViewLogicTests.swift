import Foundation
import MainternanceDomain
@testable import MainternancePresentation
import Testing

@MainActor
struct ScannerHelpTests {
    @Test func helpTextForTheInertScanButtonIsHonest() {
        #expect(ScannerHelp.scanFromScanner == "Start a scan from the Scanner screen")
    }
}
