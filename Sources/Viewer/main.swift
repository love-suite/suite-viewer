import AppKit
import SuiteCore
import ViewerUI
import SuiteFilesCore

/// Viewer: the picture viewer as an app of its own, with its own Dock icon, so pictures open
/// next to Explorer as they would in Preview or Windows' Photos.
final class ViewerDelegate: NSObject, NSApplicationDelegate {
    private var openedFiles = false

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Folders are sorted as in Explorer, whose settings live under its own name.
        if let explorer = UserDefaults(suiteName: "local.suite.explorer") {
            PictureViewer.folderViews = FolderViewStore(defaults: explorer)
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        openedFiles = true
        if let first = urls.first { PictureViewer.openFile(first) }
    }

    /// Viewer keeps itself up to date from its own releases. It quits with its last window, so it is
    /// replaced in place, never relaunched: the next picture opens in the new version.
    static let updater = SuiteUpdater(appName: "Viewer", isBusy: { false }, relaunch: {})

    func applicationDidFinishLaunching(_ notification: Notification) {
        Self.updater.start()
        if let path = CommandLine.arguments.dropFirst().first(where: { !$0.hasPrefix("-") }) {
            PictureViewer.openFile(URL(fileURLWithPath: path))
        } else {
            // Started on its own: ask for a file, unless Finder or Explorer are handing one over.
            DispatchQueue.main.async { if !self.openedFiles { self.openDocument(nil) } }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    @objc func openDocument(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image, .pdf]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else {
            if NSApp.windows.allSatisfy({ !$0.isVisible }) { NSApp.terminate(nil) }
            return
        }
        PictureViewer.openFile(url)
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)
app.mainMenu = PictureViewer.makeMenu()
let delegate = ViewerDelegate()
app.delegate = delegate
app.run()
