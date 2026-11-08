import Darwin
import Foundation
@testable import MainternanceData
import Testing

/// A small temporary disk image, attached with `-nobrowse` at a mount point inside a temp folder, so the real
/// `FileManager.trashItem` moves items into that volume's own `.Trashes/<uid>` and never into the owner's Trash.
/// `attach` gives nil when `hdiutil` cannot create or attach the image (or the mount point is not a volume of its
/// own); the image is always detached on deinit.
final class TrashDiskImage {
    static let hdiutil = "/usr/bin/hdiutil"
    /// Long enough for a slow `hdiutil`, short enough that a stuck one never hangs the test run.
    private static let timeout: TimeInterval = 60

    let temp: TempDirectory
    let mount: URL

    private init(temp: TempDirectory, mount: URL) {
        self.temp = temp
        self.mount = mount
    }

    deinit {
        _ = Self.run(["detach", "-quiet", "-force", mount.path])
    }

    static func attach() -> TrashDiskImage? {
        guard FileManager.default.isExecutableFile(atPath: hdiutil), let temp = try? TempDirectory() else { return nil }
        let mount = temp.url.appendingPathComponent("mount", isDirectory: true)
        let image = temp.url.appendingPathComponent("trash-test.dmg").path
        guard (try? FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true)) != nil,
              run(["create", "-quiet", "-size", "8m", "-fs", "APFS", "-volname", "MainternanceTrashTest", image])
        else {
            return nil
        }
        guard run(["attach", "-quiet", "-nobrowse", "-noautoopen", "-mountpoint", mount.path, image]) else {
            // A failed or timed-out attach may still have mounted the image: never leave it behind.
            _ = run(["detach", "-quiet", "-force", mount.path])
            return nil
        }
        // From here deinit detaches, also when the checks below give up.
        let attached = TrashDiskImage(temp: temp, mount: mount)
        return attached.isOwnVolume ? attached : nil
    }

    /// The mount point is the root of a volume other than the temp folder's: only then can `trashItem` not reach
    /// the owner's Trash.
    private var isOwnVolume: Bool {
        var mounted = statfs()
        var parent = statfs()
        guard statfs(mount.path, &mounted) == 0, statfs(temp.url.path, &parent) == 0, let resolved = realpath(
            mount.path,
            nil
        ) else { return false }
        defer { free(resolved) }
        let mountedOn = withUnsafeBytes(of: mounted.f_mntonname, Self.text)
        return mountedOn == String(cString: resolved) && mounted.f_fsid.val.0 != parent.f_fsid.val.0
    }

    private static func text(_ bytes: UnsafeRawBufferPointer) -> String {
        String(bytes: bytes.prefix { $0 != 0 }, encoding: .utf8) ?? ""
    }

    /// The Trash macOS picks for items on the image, when it lies inside the mount point; nil otherwise (for
    /// example the owner's own Trash), and then the test must not move anything.
    var trashOnImage: URL? {
        let manager = FileManager.default
        guard let trash = try? manager.url(
                  for: .trashDirectory,
                  in: .userDomainMask,
                  appropriateFor: mount,
                  create: true
              ),
              let root = Self.realPath(mount.path), let picked = Self.realPath(trash.path),
              picked.hasPrefix(root + "/")
        else { return nil }
        return trash
    }

    private static func realPath(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// The volume's own Trash folder for this user.
    var trashFolder: URL {
        mount.appendingPathComponent(".Trashes/\(getuid())", isDirectory: true)
    }

    private static func run(_ arguments: [String]) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: hdiutil)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        guard (try? process.run()) != nil else { return false }
        guard finished.wait(timeout: .now() + timeout) == .success else {
            process.terminate()
            return false
        }
        return process.terminationStatus == 0
    }
}

/// The real move to the Trash (`SystemTrash.move`, used by Cleanup, the Uninstaller, Files and the damaged-file
/// rotation) on a temporary disk image: a link goes to the Trash as the link itself and what it points to stays.
/// Skipped when `hdiutil` cannot attach an image here; never touches the owner's Trash.
@Suite("System Trash (real trashItem on a disk image)", .serialized)
struct SystemTrashIntegrationTests {
    /// Cancels the test unless the image is attached AND macOS would put its items in the image's own Trash, so
    /// nothing can ever reach the owner's Trash.
    private func image() throws -> TrashDiskImage {
        guard let image = TrashDiskImage.attach() else {
            try Test.cancel("hdiutil could not attach a temporary disk image here")
        }
        guard image.trashOnImage != nil else {
            try Test.cancel("the Trash for the disk image is not on the image")
        }
        return image
    }

    @Test("a link to a folder is moved as the link: the folder and its contents stay where they were")
    func folderLinkMovesAsTheLink() throws {
        let image = try image()
        let manager = FileManager.default
        let target = image.mount.appendingPathComponent("Taxes", isDirectory: true)
        try manager.createDirectory(at: target, withIntermediateDirectories: true)
        try Data("keep".utf8).write(to: target.appendingPathComponent("return.pdf"))
        let link = image.mount.appendingPathComponent("cache-link")
        try manager.createSymbolicLink(at: link, withDestinationURL: target)

        try SystemTrash.move(link)

        #expect((try? manager.destinationOfSymbolicLink(atPath: link.path)) == nil) // the link left its place
        let trashed = image.trashFolder.appendingPathComponent("cache-link")
        #expect(try manager.destinationOfSymbolicLink(atPath: trashed.path) == target.path) // still a link
        #expect(try manager.contentsOfDirectory(atPath: target.path) == ["return.pdf"])
        let kept = try String(contentsOf: target.appendingPathComponent("return.pdf"), encoding: .utf8)
        #expect(kept == "keep")
        #expect(!manager.fileExists(atPath: image.trashFolder.appendingPathComponent("Taxes").path))
    }

    @Test("a link to a file is moved as the link: the file stays")
    func fileLinkMovesAsTheLink() throws {
        let image = try image()
        let manager = FileManager.default
        let target = image.mount.appendingPathComponent("photo.jpg")
        try Data("picture".utf8).write(to: target)
        let link = image.mount.appendingPathComponent("photo-link")
        try manager.createSymbolicLink(at: link, withDestinationURL: target)

        try SystemTrash.move(link)

        let trashed = image.trashFolder.appendingPathComponent("photo-link")
        #expect(try manager.destinationOfSymbolicLink(atPath: trashed.path) == target.path)
        #expect(try String(contentsOf: target, encoding: .utf8) == "picture")
        #expect(!manager.fileExists(atPath: image.trashFolder.appendingPathComponent("photo.jpg").path))
    }
}
