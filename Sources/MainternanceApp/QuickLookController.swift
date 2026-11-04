import AppKit
import Quartz

/// Shows the system Quick Look panel for one file. Only the App target talks to AppKit; the Files screen just calls
/// a closure with the file's real path.
@MainActor
final class QuickLookController: NSObject, QLPreviewPanelDataSource {
    private var url: URL?

    func show(path: String) {
        url = URL(fileURLWithPath: path)
        guard let panel = QLPreviewPanel.shared() else { return }
        panel.dataSource = self
        panel.reloadData()
        panel.makeKeyAndOrderFront(nil)
    }

    nonisolated func numberOfPreviewItems(in _: QLPreviewPanel!) -> Int {
        MainActor.assumeIsolated { url == nil ? 0 : 1 }
    }

    nonisolated func previewPanel(_: QLPreviewPanel!, previewItemAt _: Int) -> (any QLPreviewItem)! {
        MainActor.assumeIsolated { url as NSURL? }
    }
}
