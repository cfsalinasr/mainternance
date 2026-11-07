import Foundation

/// The one real move to the owner's Trash, used by Cleanup, the Uninstaller, Files and the app's own damaged-file
/// rotation: Finder's Put Back can restore what it moves. A link is moved as the link itself and its target stays
/// where it is; `SystemTrashIntegrationTests` pins that on a temporary disk image (never the owner's Trash).
public enum SystemTrash {
    public static func move(_ url: URL) throws {
        try FileManager.default.trashItem(at: url, resultingItemURL: nil)
    }
}
