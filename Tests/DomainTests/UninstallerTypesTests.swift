import Foundation
import MainternanceDomain
import Testing

@Suite("Uninstaller types")
struct UninstallerTypesTests {
    @Test("an app is identified by its path and shown without control or bidi characters")
    func appDisplay() {
        let app = InstalledApp(
            path: "/Applications/Evil.app", name: "Ev\u{202E}il\nApp", bundleID: nil, version: nil
        )
        #expect(app.id == "/Applications/Evil.app")
        #expect(app.displayName == "Evil App")
    }

    @Test("an app with an empty name is shown by its folder name")
    func emptyName() {
        let app = InstalledApp(path: "/Applications/Foo.app", name: "\u{200B}", bundleID: nil, version: nil)
        #expect(app.displayName == "Foo.app")
    }

    @Test("only an identifier match starts ticked")
    func defaults() {
        #expect(LeftoverMatch.identifier.isSelectedByDefault)
        #expect(!LeftoverMatch.nameOnly.isSelectedByDefault)
        #expect(!LeftoverMatch.launchAgent.isSelectedByDefault)
    }

    @Test("a leftover is named after its last path component, cleaned for display, and never negative")
    func leftover() {
        let item = Leftover(
            path: "/Users/me/Library/Caches/a\u{202E}b", location: "Caches", match: .identifier, bytes: -5,
            isLowerBound: true, type: .directory
        )
        #expect(item.id == "/Users/me/Library/Caches/a\u{202E}b")
        #expect(item.name == "a\u{202E}b")
        #expect(item.displayName == "ab")
        #expect(item.bytes == 0)
    }
}
