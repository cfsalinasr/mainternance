import Foundation
import MainternanceDomain
@testable import MainternancePresentation
import Testing

/// Rules that used to sit in views and now live in testable state types.
@MainActor
struct ViewLogicTests {
    @Test func leftoverDisplayNameIsTheLastPathComponent() {
        func name(_ path: String) -> String {
            Leftover(id: path, path: path, bytes: 0).displayName
        }
        #expect(name("~/Library/Logs/VideoEditor") == "VideoEditor")
        #expect(name("~/Library/Logs/VideoEditor/") == "VideoEditor")
        #expect(name("~/") == "~")
        #expect(name("/") == "/")
        #expect(name("").isEmpty)
    }
}

@MainActor
struct ScannerHelpTests {
    @Test func helpTextForTheInertScanButtonIsHonest() {
        #expect(ScannerHelp.scanFromScanner == "Start a scan from the Scanner screen")
    }
}
