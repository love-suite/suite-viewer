import AppKit
import SuiteCore
import UniformTypeIdentifiers
import ViewerCore
import SuiteFilesCore
import SuiteFilesUI

/// The suite's picture and PDF viewer, in place of Preview and Windows' Photos: pictures fitted to the
/// window with folder navigation, zoom, full screen, the Trash, the text in the picture, and editing
/// (markup, light and colour, crop, layers) that stays editable; PDFs with page navigation and search.
/// Runs as Viewer, an app of its own. The picture window is `PictureViewerController`.
public enum PictureViewer {
    private static var controller: PictureViewerController?
    private static var pdfController: PDFViewerController?
    public static let bundleID = ViewerApp.bundleID
    /// How folders are sorted, so the arrow keys follow the order Explorer shows.
    public static var folderViews = FolderViewStore.shared

    /// Moves the file shown to the Trash. Viewer's own way records it for Explorer's Restore, plays
    /// Finder's sound and tells Explorer, whose Undo history gets it; Explorer, when it shows pictures
    /// itself, puts its own here.
    public static var moveToTrash: (URL) -> Void = { url in
        do {
            let trashed = try SuiteTrash.moveToTrash(url)
            FinderSounds.play(.moveToTrash)
            // Explorer's Undo history (Ctrl+Z, Edit › Undo) can put it back.
            SuiteTrash.announce(originals: [url], trashed: [trashed])
        } catch {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = error.localizedDescription
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
    }

    /// PDFs open in the PDF viewer.
    public static func showsPDF(_ url: URL) -> Bool { ViewerApp.showsPDF(url) }

    /// Shows the picture in this app's viewer window, with the rest of its folder a key press away.
    public static func show(_ url: URL) {
        let items = FolderFiles.sorted(url.deletingLastPathComponent(), store: folderViews)
        let viewer = controller ?? PictureViewerController()
        controller = viewer
        viewer.show(PictureSequence(items: items, current: url))
        viewer.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Routes a file to the picture viewer or the PDF viewer; for use inside the Viewer app.
    public static func openFile(_ url: URL) {
        if showsPDF(url) { showPDF(url) } else { show(url) }
    }

    /// Shows the PDF in this app's PDF viewer window.
    public static func showPDF(_ url: URL) {
        let viewer = pdfController ?? PDFViewerController()
        pdfController = viewer
        viewer.show(url)
        viewer.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Before quitting: leaves editing, writing the changes into the picture. False to stay open.
    public static func prepareToQuit() -> Bool {
        controller?.finishEditing() ?? true
    }
}
