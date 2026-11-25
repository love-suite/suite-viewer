import AppKit
import SuiteCore
import UniformTypeIdentifiers
import ViewerCore
import SuiteFilesCore
import SuiteFilesUI

/// Explorer's picture and PDF viewer — pictures fitted to the window with folder navigation, PDFs with
/// page navigation and search. Runs as Viewer, an app of its own.
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

    /// Viewer's menu bar.
    public static func makeMenu() -> NSMenu {
        let main = NSMenu()
        func submenu(_ title: String) -> NSMenu {
            let menu = NSMenu(title: title)
            main.addItem(withTitle: title, action: nil, keyEquivalent: "").submenu = menu
            return menu
        }
        func add(_ menu: NSMenu, _ title: String, _ action: String, _ key: String = "",
                 _ modifiers: NSEvent.ModifierFlags = .command) {
            let item = menu.addItem(withTitle: title, action: Selector((action)), keyEquivalent: key)
            item.keyEquivalentModifierMask = modifiers
        }
        let app = submenu("Viewer")
        add(app, UIL("About Viewer"), "orderFrontStandardAboutPanel:")
        app.addItem(.separator())
        add(app, UIL("Hide Viewer"), "hide:", "h")
        add(app, UIL("Quit Viewer"), "terminate:", "q")
        let file = submenu(UIL("File"))
        add(file, UIL("Open"), "openDocument:", "o")
        add(file, UIL("Open in Preview"), "openInPreview")
        add(file, UIL("Move to Trash"), "trash", "\u{8}")
        file.addItem(.separator())
        add(file, UIL("Close"), "performClose:", "w")
        let edit = submenu(UIL("Edit"))
        add(edit, UIL("Find"), "find:", "f")
        let view = submenu(UIL("View"))
        add(view, UIL("Zoom In"), "zoomIn", "+")
        add(view, UIL("Zoom Out"), "zoomOut", "-")
        add(view, UIL("Fit to Window"), "fit", "0")
        view.addItem(.separator())
        add(view, UIL("Show Thumbnails"), "toggleThumbnails", "2", [.command, .control])
        view.addItem(.separator())
        add(view, UIL("Enter Full Screen"), "toggleFullScreen:", "f", [.command, .control])
        let go = submenu(UIL("Go"))
        add(go, UIL("Previous"), "previous", "\u{F702}", [])
        add(go, UIL("Next"), "next", "\u{F703}", [])
        let window = submenu(UIL("Window"))
        add(window, UIL("Minimize"), "performMiniaturize:", "m")
        NSApp.windowsMenu = window
        return main
    }
}

/// Keeps a picture smaller than the window in its middle.
private final class CenteringClipView: NSClipView {
    override func constrainBoundsRect(_ proposed: NSRect) -> NSRect {
        var rect = super.constrainBoundsRect(proposed)
        guard let document = documentView else { return rect }
        if rect.width > document.frame.width { rect.origin.x = (document.frame.width - rect.width) / 2 }
        if rect.height > document.frame.height { rect.origin.y = (document.frame.height - rect.height) / 2 }
        return rect
    }
}

private final class ViewerWindow: NSWindow {
    var keyHandler: ((NSEvent) -> Bool)?

    override func keyDown(with event: NSEvent) {
        if keyHandler?(event) != true { super.keyDown(with: event) }
    }
}

final class PictureViewerController: NSWindowController, NSWindowDelegate, NSToolbarDelegate {
    private var sequence = PictureSequence(items: [], current: URL(fileURLWithPath: "/"))
    private let scroll = NSScrollView()
    private let imageView = NSImageView()
    private let message = NSTextField(labelWithString: "")
    /// The picture follows the window's size until the user zooms.
    private var fits = true

    private static let items: [NSToolbarItem.Identifier] = [
        .init("previous"), .init("next"), .flexibleSpace, .init("zoomOut"), .init("fit"), .init("zoomIn"),
        .flexibleSpace, .init("trash"), .init("preview"),
    ]

    init() {
        let window = ViewerWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 640),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                                  backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 360, height: 260)
        window.toolbarStyle = .unified
        window.tabbingMode = .disallowed
        window.setFrameAutosaveName("PictureViewer")
        super.init(window: window)
        window.delegate = self
        window.keyHandler = { [weak self] in self?.handleKey($0) ?? false }

        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.animates = true
        scroll.contentView = CenteringClipView()
        scroll.documentView = imageView
        scroll.allowsMagnification = true
        scroll.minMagnification = 0.05
        scroll.maxMagnification = 16
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.backgroundColor = .black
        scroll.drawsBackground = true
        NotificationCenter.default.addObserver(self, selector: #selector(userZoomed),
                                               name: NSScrollView.didEndLiveMagnifyNotification, object: scroll)

        message.textColor = .secondaryLabelColor
        message.alignment = .center
        message.isHidden = true
        let container = NSView()
        for view in [scroll, message] {
            view.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(view)
        }
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: container.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            message.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            message.centerYAnchor.constraint(equalTo: container.centerYAnchor),
        ])
        window.contentView = container

        let toolbar = NSToolbar(identifier: "PictureViewer")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        window.toolbar = toolbar
        if window.frame.origin == .zero { window.center() }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func show(_ sequence: PictureSequence) {
        self.sequence = sequence
        showCurrent()
    }

    private func showCurrent() {
        guard let window else { return }
        guard let url = sequence.current else {
            window.close()
            return
        }
        window.title = url.lastPathComponent
        window.subtitle = sequence.urls.count > 1
            ? "\(sequence.index + 1) \(UIL("of")) \(sequence.urls.count)" : ""
        window.representedURL = url
        if let image = NSImage(contentsOf: url) {
            message.isHidden = true
            imageView.image = image
            imageView.frame = NSRect(origin: .zero, size: Self.pixelSize(of: image))
            fitToWindow()
            // The first time, the window isn't laid out yet: fit again once it is.
            DispatchQueue.main.async { [weak self] in self?.fitToWindow() }
        } else {
            imageView.image = nil
            imageView.frame = .zero
            message.stringValue = String(format: UIL("Can't open \"%@\"."), url.lastPathComponent)
            message.isHidden = false
        }
    }

    /// Point size showing one image pixel per screen pixel at 100 %, as photo viewers do.
    private static func pixelSize(of image: NSImage) -> NSSize {
        guard let rep = image.representations.first, rep.pixelsWide > 0, rep.pixelsHigh > 0 else { return image.size }
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        return NSSize(width: CGFloat(rep.pixelsWide) / scale, height: CGFloat(rep.pixelsHigh) / scale)
    }

    /// The whole picture in the window, the view every picture opens in; small pictures stay at their own
    /// size rather than turn blurry.
    private func fitToWindow() {
        fits = true
        window?.contentView?.layoutSubtreeIfNeeded()
        let picture = imageView.frame.size
        let room = scroll.contentSize
        guard picture.width > 0, picture.height > 0, room.width > 0 else { return }
        let scale = min(room.width / picture.width, room.height / picture.height, 1)
        scroll.magnification = scale
    }

    private func zoom(by factor: CGFloat) {
        fits = false
        let center = NSPoint(x: scroll.contentView.bounds.midX, y: scroll.contentView.bounds.midY)
        scroll.setMagnification(scroll.magnification * factor, centeredAt: center)
    }

    @objc private func userZoomed() { fits = false }

    func windowDidResize(_ notification: Notification) {
        if fits { fitToWindow() }
    }

    // MARK: Commands

    @objc private func previous() { sequence.previous(); showCurrent() }
    @objc private func next() { sequence.next(); showCurrent() }
    @objc private func zoomIn() { zoom(by: 1.25) }
    @objc private func zoomOut() { zoom(by: 0.8) }
    @objc private func fit() { fitToWindow() }

    @objc private func trash() {
        guard let url = sequence.current else { return }
        PictureViewer.moveToTrash(url)
        guard !FileManager.default.fileExists(atPath: url.path) else { return }
        sequence.removeCurrent()
        showCurrent()
    }

    /// Preview, for editing, markup and everything this viewer doesn't do yet.
    @objc private func openInPreview() {
        guard let url = sequence.current,
              let preview = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Preview") else { return }
        NSWorkspace.shared.open([url], withApplicationAt: preview, configuration: NSWorkspace.OpenConfiguration())
    }

    /// Arrows go through the folder, as in Windows' Photos; Delete trashes; Escape leaves full screen.
    private func handleKey(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .control, .option])
        switch (event.keyCode, flags) {
        case (123, []), (126, []): previous()                  // left, up
        case (124, []), (125, []), (49, []): next()            // right, down, space
        case (51, []), (117, []), (51, .command): trash()      // backspace, forward delete, Cmd+Backspace
        case (53, []):                                           // Escape
            if window?.styleMask.contains(.fullScreen) == true { window?.toggleFullScreen(nil) } else { return false }
        default:
            switch (event.charactersIgnoringModifiers, flags) {
            case ("=", .command), ("+", .command), ("+", []): zoomIn()
            case ("-", .command), ("-", []): zoomOut()
            case ("0", .command): fit()
            case ("f", []): window?.toggleFullScreen(nil)
            default: return false
            }
        }
        return true
    }

    // MARK: Toolbar

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { Self.items }
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { Self.items }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        let specs: [String: (String, String, Selector)] = [
            "previous": ("chevron.left", UIL("Previous"), #selector(previous)),
            "next": ("chevron.right", UIL("Next"), #selector(next)),
            "zoomOut": ("minus.magnifyingglass", UIL("Zoom Out"), #selector(zoomOut)),
            "fit": ("arrow.up.left.and.arrow.down.right", UIL("Fit to Window"), #selector(fit)),
            "zoomIn": ("plus.magnifyingglass", UIL("Zoom In"), #selector(zoomIn)),
            "trash": ("trash", UIL("Move to Trash"), #selector(trash)),
            "preview": ("square.and.pencil", UIL("Open in Preview"), #selector(openInPreview)),
        ]
        guard let (symbol, label, action) = specs[identifier.rawValue] else { return nil }
        let item = NSToolbarItem(itemIdentifier: identifier)
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        item.label = label
        item.toolTip = label
        item.target = self
        item.action = action
        item.isBordered = true
        return item
    }
}
