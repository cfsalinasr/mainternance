import Foundation
@testable import MainternanceData
import Testing

@Suite("Protected paths")
struct ProtectedPathsTests {
    @Test("system locations and the root are protected", arguments: [
        "/", "/System", "/System/Library/CoreServices/Finder.app", "/usr/bin/ls", "/bin/sh", "/sbin/mount",
        "/Library/Apple/usr/bin/x", "/private/var/db/dslocal/x", "/private/etc/hosts"
    ])
    func systemPaths(path: String) {
        #expect(ProtectedPaths.isProtected(path))
    }

    @Test("aliases, dot-dot, trailing slashes and letter case cannot dodge protection", arguments: [
        "/etc/hosts", "/var/db/x", "/tmp/../System/Library", "/Users/../usr/bin/ls", "/system/library", "/USR/bin",
        "/System/", "//System///Library"
    ])
    func evasions(path: String) {
        #expect(ProtectedPaths.isProtected(path))
    }

    @Test("relative paths are refused")
    func relative() {
        #expect(ProtectedPaths.isProtected("Downloads/a.txt"))
        #expect(ProtectedPaths.isProtected(""))
    }

    @Test("the home folder itself is protected but files inside it are not")
    func home() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        #expect(ProtectedPaths.isProtected(home))
        #expect(ProtectedPaths.isProtected(home + "/"))
        #expect(!ProtectedPaths.isProtected(home + "/Downloads/mainternance-not-real.zip"))
    }

    @Test("ordinary locations are not protected")
    func ordinary() {
        #expect(!ProtectedPaths.isProtected("/Applications/Foo.app/Contents/x"))
        #expect(!ProtectedPaths.isProtected("/usr/local/bin/tool"))
        #expect(!ProtectedPaths.isProtected("/usr/local/../local/x"))
        #expect(ProtectedPaths.isProtected("/usr/local/../bin/ls"))
        #expect(ProtectedPaths.isProtected("/usr/libexec/x"))
        #expect(ProtectedPaths.isProtected("/usr/localx/x"))
        #expect(!ProtectedPaths.isProtected("/private/var/folders/ab/x/T/a.txt"))
        #expect(!ProtectedPaths.isProtected("/Library/Caches/x"))
        #expect(!ProtectedPaths.isProtected("/Users/someone/Downloads/a.txt"))
    }

    @Test("the running app bundle is protected, with everything inside it")
    func bundle() {
        let bundle = Bundle.main.bundlePath
        #expect(ProtectedPaths.isProtected(bundle))
        #expect(ProtectedPaths.isProtected(bundle + "/Contents/MacOS/x"))
    }

    @Test("extra protected folders protect themselves and everything below")
    func extras() {
        let extra = URL(fileURLWithPath: "/private/var/folders/zz/Quarantine", isDirectory: true)
        #expect(ProtectedPaths.isProtected(extra.path, including: [extra]))
        #expect(ProtectedPaths.isProtected(extra.path + "/abc", including: [extra]))
        #expect(!ProtectedPaths.isProtected("/private/var/folders/zz/Quarantine2/abc", including: [extra]))
        #expect(!ProtectedPaths.isProtected(extra.path + "/abc"))
    }

    @Test("a symlink into a protected folder is protected")
    func symlinkPrefix() throws {
        let temp = try TempDirectory()
        let link = temp.url.appendingPathComponent("sys")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "/usr")
        #expect(ProtectedPaths.isProtected(link.path + "/bin/ls"))
    }
}
