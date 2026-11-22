import AppKit
import Combine
import PictureEditCore
import SuiteCore
import SwiftUI
import UniformTypeIdentifiers
import ViewerCore

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

/// The viewer's window. Viewing: the picture fitted under the toolbar, the folder a key press away,
/// its text selectable and searchable. Editing (Edit, or E): the tool strip under the toolbar, the
/// Adjust, Layers and History panel on the right; Done writes the picture into its file, while its
/// editable version and original stay in the viewer's store.
final class PictureViewerController: NSWindowController, NSWindowDelegate, NSToolbarDelegate, NSMenuItemValidation,
    NSSearchFieldDelegate {
    private var sequence = PictureSequence(items: [], current: URL(fileURLWithPath: "/"))
    let scroll = NSScrollView()
    let canvas = PictureCanvas()
    private let message = NSTextField(labelWithString: "")
    private let stripHost = NSHostingView(rootView: AnyView(EmptyView()))
    private let sidebarHost = NSHostingView(rootView: AnyView(EmptyView()))
    /// The picture follows the window's size until the user zooms.
    private var fits = true
    private(set) var editor: PictureEditor?
    private var editorObservation: AnyCancellable?
    private var currentImage: NSImage?
    private var textToken = UUID()
    private var textCache: [URL: RecognizedText] = [:]
    private weak var searchField: NSSearchField?

    private static let items: [NSToolbarItem.Identifier] = [
        .init("previous"), .init("next"), .flexibleSpace, .init("zoomOut"), .init("fit"), .init("zoomIn"),
        .flexibleSpace, .init("text"), .init("search"), .init("rotate"), .init("edit"), .init("trash"),
    ]

    init() {
        let window = ViewerWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable],
                                  backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 560, height: 360)
        window.toolbarStyle = .unified
        window.tabbingMode = .disallowed
        window.setFrameAutosaveName("PictureViewer")
        super.init(window: window)
        window.delegate = self
        window.keyHandler = { [weak self] in self?.handleKey($0) ?? false }

        canvas.pointsPerPixel = 1 / (window.backingScaleFactor > 0 ? window.backingScaleFactor : 2)
        canvas.onResize = { [weak self] in if self?.fits == true { self?.fitToWindow() } }
        canvas.menuProvider = { [weak self] event, point in self?.contextMenu(at: point) }
        scroll.contentView = CenteringClipView()
        scroll.documentView = canvas
        scroll.allowsMagnification = true
        scroll.minMagnification = 0.02
        scroll.maxMagnification = 32
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
        stripHost.isHidden = true
        sidebarHost.isHidden = true

        // The scroll view sits below the toolbar (no full-size content view), so a fitted picture is
        // entirely visible rather than partly under the toolbar.
        let middle = NSStackView(views: [scroll, sidebarHost])
        middle.orientation = .horizontal
        middle.spacing = 0
        middle.distribution = .fill
        let column = NSStackView(views: [stripHost, middle])
        column.orientation = .vertical
        column.spacing = 0
        column.alignment = .leading
        column.distribution = .fill
        for view in [stripHost, middle] {
            view.translatesAutoresizingMaskIntoConstraints = false
            view.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
        }
        scroll.setContentHuggingPriority(.defaultLow, for: .horizontal)
        // The panel takes the whole height beside the picture, 260 points wide.
        sidebarHost.sizingOptions = []
        sidebarHost.translatesAutoresizingMaskIntoConstraints = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            sidebarHost.widthAnchor.constraint(equalToConstant: 260),
            sidebarHost.heightAnchor.constraint(equalTo: middle.heightAnchor),
            scroll.heightAnchor.constraint(equalTo: middle.heightAnchor),
        ])
        stripHost.setContentHuggingPriority(.required, for: .vertical)
        let container = NSView()
        for view in [column, message] {
            view.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(view)
        }
        NSLayoutConstraint.activate([
            column.topAnchor.constraint(equalTo: container.topAnchor),
            column.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            column.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            column.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            message.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            message.centerYAnchor.constraint(equalTo: container.centerYAnchor),
        ])
        window.contentView = container

        let toolbar = NSToolbar(identifier: "PictureViewer2")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        window.toolbar = toolbar
        if window.frame.origin == .zero { window.center() }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    // MARK: Showing pictures

    func show(_ sequence: PictureSequence) {
        guard finishEditing() else { return }
        self.sequence = sequence
        showCurrent()
    }

    private func showCurrent() {
        guard let window else { return }
        guard let url = sequence.current else {
            window.close()
            return
        }
        window.representedURL = url
        updateTitle()
        if let image = NSImage(contentsOf: url) {
            message.isHidden = true
            currentImage = image
            canvas.showPicture(image, pixelSize: Self.pixelSize(of: image))
            fitToWindow()
            // The first time, the window isn't laid out yet: fit again once it is.
            DispatchQueue.main.async { [weak self] in if self?.fits == true { self?.fitToWindow() } }
            recognizeText(in: url)
        } else {
            currentImage = nil
            canvas.showPicture(nil, pixelSize: .zero)
            message.stringValue = "Can't open “\(url.lastPathComponent)”."
            message.isHidden = false
        }
    }

    private func updateTitle() {
        guard let window, let url = sequence.current else { return }
        window.title = url.lastPathComponent
        var subtitle = sequence.urls.count > 1 ? sequence.position : ""
        if let editor {
            let state = editor.hasUnsavedChanges ? "Editing, saved when you click Done" : "Editing"
            subtitle = subtitle.isEmpty ? state : subtitle + " · " + state
        }
        window.subtitle = subtitle
        window.isDocumentEdited = editor?.hasUnsavedChanges ?? false
        if let item = window.toolbar?.items.first(where: { $0.itemIdentifier.rawValue == "edit" }) {
            let editing = editor != nil
            item.label = editing ? "Done" : "Edit"
            item.toolTip = editing ? "Done: save the changes into the picture" : "Edit and Mark Up (E)"
            item.image = NSImage(systemSymbolName: editing ? "checkmark.circle.fill" : "pencil.tip.crop.circle",
                                 accessibilityDescription: item.label)
        }
    }

    /// Point size showing one image pixel per screen pixel at 100 %, as photo viewers do.
    private static func pixelSize(of image: NSImage) -> NSSize {
        guard let rep = image.representations.first, rep.pixelsWide > 0, rep.pixelsHigh > 0 else {
            return NSSize(width: image.size.width * 2, height: image.size.height * 2)
        }
        return NSSize(width: CGFloat(rep.pixelsWide), height: CGFloat(rep.pixelsHigh))
    }

    /// The whole picture in the room left by the toolbar, the edit strip and panel; small pictures stay
    /// at their own size rather than turn blurry.
    private func fitToWindow() {
        fits = true
        window?.contentView?.layoutSubtreeIfNeeded()
        let picture = canvas.frame.size
        let room = scroll.contentSize
        guard picture.width > 0, picture.height > 0, room.width > 0, room.height > 0 else { return }
        let margin: CGFloat = editor == nil ? 0 : 24
        let scale = min((room.width - margin) / picture.width, (room.height - margin) / picture.height, 1)
        scroll.magnification = scale
        canvas.needsDisplay = true
    }

    private func zoom(by factor: CGFloat) {
        fits = false
        let center = NSPoint(x: scroll.contentView.bounds.midX, y: scroll.contentView.bounds.midY)
        scroll.setMagnification(scroll.magnification * factor, centeredAt: center)
        canvas.needsDisplay = true
    }

    @objc private func userZoomed() {
        fits = false
        canvas.needsDisplay = true
    }

    func windowDidResize(_ notification: Notification) {
        if fits { fitToWindow() }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool { finishEditing() }

    // MARK: Text in the picture

    /// Reads the text a moment after the picture shows (not while flicking through a folder).
    private func recognizeText(in url: URL) {
        let token = UUID()
        textToken = token
        if let cached = textCache[url] {
            canvas.recognized = cached
            updateSearch()
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            guard let self, self.textToken == token else { return }
            DispatchQueue.global(qos: .utility).async {
                let text = PictureFile.loadUpright(url).map(TextRecognition.recognize) ?? .empty
                DispatchQueue.main.async {
                    if self.textCache.count > 30 { self.textCache.removeAll() }
                    self.textCache[url] = text
                    guard self.textToken == token else { return }
                    self.canvas.recognized = text
                    self.updateSearch()
                }
            }
        }
    }

    @objc private func toggleText() {
        canvas.showsAllText.toggle()
        if canvas.showsAllText && canvas.recognized.isEmpty && editor == nil {
            message.stringValue = "No text found in this picture."
            message.isHidden = !canvas.recognized.isEmpty
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                if self?.currentImage != nil { self?.message.isHidden = true }
            }
        }
    }

    @objc func copyAllText(_ sender: Any?) {
        guard !canvas.recognized.isEmpty else { return }
        copyString(canvas.recognized.fullText)
    }

    @objc func selectAllText(_ sender: Any?) {
        guard !canvas.recognized.isEmpty else { return }
        canvas.textSelection = 0...(canvas.recognized.words.count - 1)
    }

    private func copyString(_ string: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
    }

    @objc func findInPicture(_ sender: Any?) {
        guard editor == nil else { return }
        window?.makeFirstResponder(searchField)
    }

    func controlTextDidChange(_ notification: Notification) { updateSearch() }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.insertNewline(_:)) {
            nextMatch(backwards: NSEvent.modifierFlags.contains(.shift))
            return true
        }
        if selector == #selector(NSResponder.cancelOperation(_:)) {
            searchField?.stringValue = ""
            updateSearch()
            window?.makeFirstResponder(canvas)
            return true
        }
        return false
    }

    private func updateSearch() {
        let query = searchField?.stringValue ?? ""
        canvas.matches = canvas.recognized.matches(of: query)
        canvas.currentMatch = canvas.matches.isEmpty ? nil : 0
        revealMatch()
    }

    private func nextMatch(backwards: Bool) {
        guard !canvas.matches.isEmpty else { return }
        let count = canvas.matches.count
        canvas.currentMatch = ((canvas.currentMatch ?? -1) + (backwards ? -1 : 1) + count) % count
        revealMatch()
    }

    private func revealMatch() {
        guard let index = canvas.currentMatch, let rect = canvas.viewRects(for: canvas.matches[index]).first else { return }
        canvas.scrollToVisible(rect.insetBy(dx: -40, dy: -40))
    }

    // MARK: Editing

    @objc func toggleEditing(_ sender: Any?) {
        if editor != nil { _ = finishEditing() } else { startEditing() }
    }

    @discardableResult
    private func startEditing() -> PictureEditor? {
        if let editor { return editor }
        guard let url = sequence.current else { return nil }
        guard let editor = PictureEditor(url: url) else {
            alert("“\(url.lastPathComponent)” can't be edited.", "The picture couldn't be read.")
            return nil
        }
        self.editor = editor
        canvas.showsAllText = false
        canvas.startEditing(editor)
        let actions = EditorActions(
            rotate: { [weak self] in self?.rotate(clockwise: $0) },
            flip: { [weak self] in self?.flip(horizontally: $0) },
            resetCrop: { [weak self] in self?.canvas.resetCrop() },
            applyCrop: { [weak self] in self?.canvas.applyCrop(); self?.editor?.tool = .select },
            cropAspectChanged: { [weak self] in self?.canvas.cropAspectChanged() },
            insertPicture: { [weak self] in self?.insertPicture(nil) })
        stripHost.rootView = AnyView(EditorToolStrip(editor: editor, actions: actions))
        sidebarHost.rootView = AnyView(EditorSidebar(editor: editor))
        stripHost.isHidden = false
        sidebarHost.isHidden = false
        editorObservation = editor.objectWillChange.sink { [weak self] in
            DispatchQueue.main.async { self?.updateTitle() }
        }
        updateTitle()
        fitToWindow()
        DispatchQueue.main.async { [weak self] in self?.fitToWindow() }
        return editor
    }

    /// Leaves editing, writing the changes into the picture file. False when they couldn't be written
    /// and the user chose to keep editing.
    @discardableResult
    func finishEditing() -> Bool {
        guard let editor else { return true }
        canvas.endTextEditing()
        canvas.applyCrop()
        if editor.hasUnsavedChanges {
            do {
                try editor.saveToFile()
            } catch {
                editor.saveEdits()
                let alert = NSAlert()
                alert.messageText = "The changes couldn't be saved into “\(editor.url.lastPathComponent)”."
                alert.informativeText = error.localizedDescription
                    + "\n\nThey are kept in Viewer: they come back the next time you edit this picture."
                alert.addButton(withTitle: "Save as Copy")
                alert.addButton(withTitle: "Keep Editing")
                alert.addButton(withTitle: "Close Anyway")
                switch alert.runModal() {
                case .alertFirstButtonReturn:
                    guard saveCopy() else { return false }
                case .alertSecondButtonReturn:
                    return false
                default:
                    break
                }
            }
        }
        editor.saveEdits()
        canvas.stopEditing()
        self.editor = nil
        editorObservation = nil
        stripHost.isHidden = true
        sidebarHost.isHidden = true
        stripHost.rootView = AnyView(EmptyView())
        sidebarHost.rootView = AnyView(EmptyView())
        textCache[editor.url] = nil
        if sequence.current != nil { showCurrent() }
        return true
    }

    /// An edit made while viewing (turning, resizing, going back to the original): saved at once, as
    /// Windows' Photos does.
    private func quickEdit(_ name: String, _ change: (PictureEditor) -> Void) {
        guard let url = sequence.current, let editor = PictureEditor(url: url) else { return }
        change(editor)
        do {
            try editor.saveToFile()
        } catch {
            editor.saveEdits()
            alert("The picture couldn't be saved.", error.localizedDescription)
        }
        textCache[url] = nil
        showCurrent()
    }

    private func rotate(clockwise: Bool) {
        if let editor {
            canvas.applyCrop()
            editor.apply(clockwise ? "Rotate Right" : "Rotate Left") { $0.rotate(clockwise: clockwise) }
            if editor.tool == .crop { canvas.resetCropDraftToDocument() }
        } else {
            quickEdit("Rotate") { $0.apply(clockwise ? "Rotate Right" : "Rotate Left") { $0.rotate(clockwise: clockwise) } }
        }
    }

    private func flip(horizontally: Bool) {
        let name = horizontally ? "Flip Horizontal" : "Flip Vertical"
        if let editor {
            canvas.applyCrop()
            editor.apply(name) { $0.flip(horizontally: horizontally) }
            if editor.tool == .crop { canvas.resetCropDraftToDocument() }
        } else {
            quickEdit(name) { $0.apply(name) { $0.flip(horizontally: horizontally) } }
        }
    }

    @objc func rotateLeft(_ sender: Any?) { rotate(clockwise: false) }
    @objc func rotateRight(_ sender: Any?) { rotate(clockwise: true) }
    @objc func flipHorizontal(_ sender: Any?) { flip(horizontally: true) }
    @objc func flipVertical(_ sender: Any?) { flip(horizontally: false) }

    @objc func cropPicture(_ sender: Any?) {
        guard let editor = startEditing() else { return }
        editor.tool = .crop
    }

    @objc func showAdjustments(_ sender: Any?) {
        guard let editor = startEditing() else { return }
        editor.panel = .adjust
    }

    @objc func showLayers(_ sender: Any?) { startEditing()?.panel = .layers }
    @objc func showHistory(_ sender: Any?) { startEditing()?.panel = .history }

    @objc func pickTool(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let tool = EditTool(rawValue: raw),
              let editor = startEditing() else { return }
        editor.tool = tool
    }

    @objc func revertToOriginal(_ sender: Any?) {
        if let editor { editor.revertToOriginal() } else { quickEdit("Revert") { $0.revertToOriginal() } }
    }

    @objc func resizeImage(_ sender: Any?) {
        guard let window, let url = sequence.current else { return }
        let probe = editor ?? PictureEditor(url: url)
        guard let probe else { return }
        let natural = probe.document.naturalSize
        let current = probe.document.finalSize
        var sheetWindow: NSWindow?
        let view = ResizeSheet(natural: natural, current: current) { [weak self] size in
            if let sheet = sheetWindow { window.endSheet(sheet) }
            guard let self, let size else { return }
            let target: CGSize? = size == natural ? nil : size
            if let editor = self.editor {
                editor.apply("Resize") { $0.outputSize = target }
            } else {
                self.quickEdit("Resize") { $0.apply("Resize") { $0.outputSize = target } }
            }
        }
        let sheet = NSWindow(contentViewController: NSHostingController(rootView: view))
        sheetWindow = sheet
        window.beginSheet(sheet)
    }

    @objc func insertPicture(_ sender: Any?) {
        guard let window else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.message = "Choose a picture to place on this one."
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url, let image = NSImage(contentsOf: url),
                  let self, let editor = self.startEditing() else { return }
            editor.insertPicture(image, center: self.canvas.visibleCenter)
        }
    }

    @objc func saveDocument(_ sender: Any?) {
        guard let editor else { return }
        canvas.endTextEditing()
        canvas.applyCrop()
        do {
            try editor.saveToFile()
        } catch {
            alert("The changes couldn't be saved into the picture.", error.localizedDescription)
        }
        updateTitle()
    }

    @objc func saveDocumentAs(_ sender: Any?) { _ = saveCopy() }

    /// Saves the picture as it shows into a new file, in a format of the user's choice.
    @discardableResult
    private func saveCopy() -> Bool {
        guard let url = sequence.current else { return false }
        let editor = self.editor ?? PictureEditor(url: url)
        guard let editor else { return false }
        canvas.endTextEditing()
        canvas.applyCrop()
        let panel = NSSavePanel()
        let types: [(String, UTType)] = [("JPEG", .jpeg), ("PNG", .png), ("HEIC", .heic), ("TIFF", .tiff)]
        let original = UTType(filenameExtension: url.pathExtension)
        var chosen = types.firstIndex { original?.conforms(to: $0.1) == true } ?? 0
        let popup = NSPopUpButton()
        popup.addItems(withTitles: types.map(\.0))
        popup.selectItem(at: chosen)
        let label = NSTextField(labelWithString: "Format:")
        let accessory = NSStackView(views: [label, popup])
        accessory.edgeInsets = NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        panel.accessoryView = accessory
        panel.allowedContentTypes = [types[chosen].1]
        panel.nameFieldStringValue = url.deletingPathExtension().lastPathComponent + " (edited)"
        panel.directoryURL = url.deletingLastPathComponent()
        let handler = PopupHandler { index in
            chosen = index
            panel.allowedContentTypes = [types[index].1]
        }
        popup.target = handler
        popup.action = #selector(PopupHandler.changed(_:))
        guard panel.runModal() == .OK, let destination = panel.url else { return false }
        do {
            try editor.saveCopy(to: destination, as: types[chosen].1)
            return true
        } catch {
            alert("The copy couldn't be saved.", error.localizedDescription)
            return false
        }
    }

    // MARK: Commands

    @objc private func previous() {
        guard finishEditing() else { return }
        sequence.previous()
        showCurrent()
    }

    @objc private func next() {
        guard finishEditing() else { return }
        sequence.next()
        showCurrent()
    }

    @objc private func zoomIn() { zoom(by: 1.25) }
    @objc private func zoomOut() { zoom(by: 0.8) }
    @objc private func fit() { fitToWindow() }

    @objc private func actualSize() {
        fits = false
        scroll.magnification = 1
        canvas.needsDisplay = true
    }

    @objc private func trash() {
        guard let url = sequence.current else { return }
        if editor != nil {
            guard finishEditing() else { return }
        }
        PictureViewer.moveToTrash(url)
        guard !FileManager.default.fileExists(atPath: url.path) else { return }
        sequence.removeCurrent()
        showCurrent()
    }

    /// Preview, for what this viewer doesn't do.
    @objc private func openInPreview() {
        guard finishEditing(), let url = sequence.current,
              let preview = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Preview") else { return }
        NSWorkspace.shared.open([url], withApplicationAt: preview, configuration: NSWorkspace.OpenConfiguration())
    }

    @objc func undo(_ sender: Any?) { editor?.undo() }
    @objc func redo(_ sender: Any?) { editor?.redo() }

    @objc func copy(_ sender: Any?) {
        if let editor {
            if editor.copySelection() { return }
            if let image = editor.flattened() {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.writeObjects([NSImage(cgImage: image, size: .zero)])
            }
        } else if let text = canvas.selectedText {
            copyString(text)
        } else if let image = currentImage {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.writeObjects([image])
        }
    }

    @objc func cut(_ sender: Any?) {
        guard let editor, editor.copySelection() else { return }
        editor.deleteSelection()
    }

    @objc func paste(_ sender: Any?) {
        guard let editor = startEditing() else { return }
        editor.paste(center: canvas.visibleCenter)
    }

    @objc func delete(_ sender: Any?) { editor?.deleteSelection() }
    @objc func duplicate(_ sender: Any?) { editor?.duplicateSelection() }

    @objc override func selectAll(_ sender: Any?) {
        if let editor { editor.selectAll() } else { selectAllText(sender) }
    }

    @objc func bringToFront(_ sender: Any?) { editor?.arrangeSelection(.front) }
    @objc func bringForward(_ sender: Any?) { editor?.arrangeSelection(.forward) }
    @objc func sendBackward(_ sender: Any?) { editor?.arrangeSelection(.backward) }
    @objc func sendToBack(_ sender: Any?) { editor?.arrangeSelection(.back) }
    @objc func newLayer(_ sender: Any?) { startEditing()?.addLayer() }

    @objc func mergeLayerDown(_ sender: Any?) {
        guard let editor else { return }
        editor.mergeDown(editor.currentLayer)
    }

    @objc func moveSelectionToLayer(_ sender: NSMenuItem) {
        guard let editor, let id = sender.representedObject as? UUID else { return }
        let shapes = editor.selection
        editor.apply("Move to Layer") { doc in for shape in shapes { doc.move(shape, toLayer: id) } }
        editor.currentLayer = id
    }

    @objc func editText(_ sender: Any?) {
        guard let editor, let id = editor.selection.first, let shape = editor.document.shape(id), shape.kind == .text else { return }
        canvas.beginTextEditing(shape)
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        let hasPicture = currentImage != nil
        let selection = editor?.selection ?? []
        switch item.action {
        case #selector(toggleEditing(_:)):
            item.title = editor == nil ? "Edit and Mark Up" : "Done Editing"
            return hasPicture
        case #selector(saveDocument(_:)): return editor?.hasUnsavedChanges == true
        case #selector(saveDocumentAs(_:)), #selector(rotateLeft(_:)), #selector(rotateRight(_:)),
             #selector(flipHorizontal(_:)), #selector(flipVertical(_:)), #selector(cropPicture(_:)),
             #selector(resizeImage(_:)), #selector(insertPicture(_:)), #selector(showAdjustments(_:)),
             #selector(showLayers(_:)), #selector(showHistory(_:)), #selector(pickTool(_:)), #selector(newLayer(_:)),
             #selector(paste(_:)):
            return hasPicture
        case #selector(revertToOriginal(_:)):
            if let editor { return editor.isEdited }
            guard let url = sequence.current else { return false }
            return PictureEditor.defaultStore.record(for: url) != nil
        case #selector(undo(_:)):
            item.title = editor?.history.undoName.map { "Undo \($0)" } ?? "Undo"
            return editor?.history.canUndo == true || (editor.map { $0.document != $0.history.current } ?? false)
        case #selector(redo(_:)):
            item.title = editor?.history.redoName.map { "Redo \($0)" } ?? "Redo"
            return editor?.history.canRedo == true
        case #selector(copy(_:)): return hasPicture
        case #selector(cut(_:)), #selector(delete(_:)), #selector(duplicate(_:)), #selector(bringToFront(_:)),
             #selector(bringForward(_:)), #selector(sendBackward(_:)), #selector(sendToBack(_:)):
            return !selection.isEmpty
        case #selector(mergeLayerDown(_:)):
            guard let editor, let index = editor.document.layerIndex(editor.currentLayer) else { return false }
            return index > 0
        case #selector(selectAll(_:)): return editor != nil || !canvas.recognized.isEmpty
        case #selector(copyAllText(_:)), #selector(selectAllText(_:)): return editor == nil && !canvas.recognized.isEmpty
        case #selector(toggleText):
            item.state = canvas.showsAllText ? .on : .off
            return editor == nil && hasPicture
        case #selector(findInPicture(_:)): return editor == nil && hasPicture
        case #selector(trash), #selector(openInPreview), #selector(zoomIn), #selector(zoomOut), #selector(fit),
             #selector(actualSize):
            return hasPicture
        default: return true
        }
    }

    private func contextMenu(at point: CGPoint?) -> NSMenu? {
        let menu = NSMenu()
        func add(_ title: String, _ action: Selector, _ object: Any? = nil) {
            let item = menu.addItem(withTitle: title, action: action, keyEquivalent: "")
            item.target = self
            item.representedObject = object
        }
        if let editor {
            if !editor.selection.isEmpty {
                if editor.selection.count == 1, let id = editor.selection.first, editor.document.shape(id)?.kind == .text {
                    add("Edit Text", #selector(editText(_:)))
                    menu.addItem(.separator())
                }
                add("Cut", #selector(cut(_:)))
                add("Copy", #selector(copy(_:)))
                add("Duplicate", #selector(duplicate(_:)))
                add("Delete", #selector(delete(_:)))
                menu.addItem(.separator())
                add("Bring to Front", #selector(bringToFront(_:)))
                add("Bring Forward", #selector(bringForward(_:)))
                add("Send Backward", #selector(sendBackward(_:)))
                add("Send to Back", #selector(sendToBack(_:)))
                let layers = editor.document.layers.reversed().filter { layer in
                    !editor.selection.allSatisfy { editor.document.locate($0).map { editor.document.layers[$0.layer].id } == layer.id }
                }
                if !layers.isEmpty {
                    let submenu = NSMenu()
                    for layer in layers {
                        let item = submenu.addItem(withTitle: layer.name, action: #selector(moveSelectionToLayer(_:)), keyEquivalent: "")
                        item.target = self
                        item.representedObject = layer.id
                    }
                    menu.addItem(withTitle: "Move to Layer", action: nil, keyEquivalent: "").submenu = submenu
                }
            } else {
                add("Paste", #selector(paste(_:)))
                add("Select All", #selector(selectAll(_:)))
                add("Insert Picture", #selector(insertPicture(_:)))
            }
            return menu
        }
        if canvas.textSelection != nil { add("Copy Text", #selector(copy(_:))) }
        if !canvas.recognized.isEmpty {
            add("Copy All Text", #selector(copyAllText(_:)))
            add("Select All Text", #selector(selectAllText(_:)))
        }
        if !menu.items.isEmpty { menu.addItem(.separator()) }
        add("Copy Picture", #selector(copyPicture(_:)))
        add("Edit and Mark Up", #selector(toggleEditing(_:)))
        add("Rotate Left", #selector(rotateLeft(_:)))
        add("Rotate Right", #selector(rotateRight(_:)))
        return menu
    }

    @objc func copyPicture(_ sender: Any?) {
        guard let image = currentImage else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([image])
    }

    // MARK: Keys

    /// Viewing: arrows go through the folder, as in Windows' Photos; Delete trashes; Escape leaves full
    /// screen; E edits. Editing: tool letters, Delete removes shapes, arrows nudge them, Escape steps back.
    private func handleKey(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
        let characters = event.charactersIgnoringModifiers?.lowercased() ?? ""
        // Windows' Ctrl+Z and Ctrl+Y, next to the Mac's Cmd+Z and Cmd+Shift+Z.
        if flags == .control || flags == .command, characters == "y" { redo(nil); return true }
        if flags == .control, characters == "z" { undo(nil); return true }
        if let editor { return handleEditingKey(event, editor, flags, characters) }
        switch (event.keyCode, flags) {
        case (123, []), (126, []): previous()                  // left, up
        case (124, []), (125, []), (49, []): next()            // right, down, space
        case (51, []), (117, []), (51, .command): trash()      // backspace, forward delete, Cmd+Backspace
        case (53, []):                                           // Escape
            if !canvas.matches.isEmpty || canvas.textSelection != nil || canvas.showsAllText {
                canvas.textSelection = nil
                canvas.showsAllText = false
            } else if window?.styleMask.contains(.fullScreen) == true {
                window?.toggleFullScreen(nil)
            } else {
                return false
            }
        default:
            switch (characters, flags) {
            case ("=", .command), ("+", .command), ("+", []), ("+", .shift), ("=", []): zoomIn()
            case ("-", .command), ("-", []): zoomOut()
            case ("0", .command): fit()
            case ("f", []): window?.toggleFullScreen(nil)
            case ("e", []): startEditing()
            case ("t", []): toggleText()
            default: return false
            }
        }
        return true
    }

    private func handleEditingKey(_ event: NSEvent, _ editor: PictureEditor, _ flags: NSEvent.ModifierFlags,
                                  _ characters: String) -> Bool {
        let step = editor.unit * (flags.contains(.shift) ? 10 : 1)
        let plain = flags.subtracting(.shift).isEmpty
        switch event.keyCode {
        case 53: // Escape
            if editor.tool == .crop { canvas.resetCropDraftToDocument(); editor.tool = .select }
            else if !editor.selection.isEmpty { editor.selection = [] }
            else if editor.tool != .select { editor.tool = .select }
            else { finishEditing() }
            return true
        case 36, 76: // Return, Enter
            if editor.tool == .crop { canvas.applyCrop(); editor.tool = .select; return true }
            if editor.selection.count == 1 { editText(nil); return true }
            return false
        case 51, 117: // Backspace, Delete
            editor.deleteSelection()
            return true
        case 123...126 where plain:
            if editor.selection.isEmpty {
                if event.keyCode == 123 || event.keyCode == 126 { previous() } else { next() }
            } else {
                let offset: CGVector = switch event.keyCode {
                case 123: CGVector(dx: -step, dy: 0)
                case 124: CGVector(dx: step, dy: 0)
                case 125: CGVector(dx: 0, dy: step)
                default: CGVector(dx: 0, dy: -step)
                }
                editor.nudgeSelection(by: offset)
            }
            return true
        default:
            break
        }
        switch (characters, flags) {
        case ("=", .command), ("+", .command): zoomIn(); return true
        case ("-", .command): zoomOut(); return true
        case ("0", .command): fit(); return true
        default: break
        }
        if flags.isEmpty, characters.count == 1, let tool = EditTool.forKey(characters.first!) {
            editor.tool = tool
            return true
        }
        return false
    }

    // MARK: Toolbar

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { Self.items }
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { Self.items }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        if identifier.rawValue == "search" {
            let item = NSSearchToolbarItem(itemIdentifier: identifier)
            item.searchField.placeholderString = "Find Text"
            item.searchField.delegate = self
            item.searchField.sendsSearchStringImmediately = true
            item.label = "Find Text"
            item.toolTip = "Find text in the picture"
            searchField = item.searchField
            return item
        }
        let specs: [String: (String, String, Selector)] = [
            "previous": ("chevron.left", "Previous", #selector(previous)),
            "next": ("chevron.right", "Next", #selector(next)),
            "zoomOut": ("minus.magnifyingglass", "Zoom Out", #selector(zoomOut)),
            "fit": ("arrow.up.left.and.arrow.down.right", "Fit to Window", #selector(fit)),
            "zoomIn": ("plus.magnifyingglass", "Zoom In", #selector(zoomIn)),
            "text": ("text.viewfinder", "Show Text (T)", #selector(toggleText)),
            "rotate": ("rotate.left", "Rotate Left", #selector(rotateLeft(_:))),
            "edit": ("pencil.tip.crop.circle", "Edit", #selector(toggleEditing(_:))),
            "trash": ("trash", "Move to Trash", #selector(trash)),
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

    private func alert(_ title: String, _ text: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        if let window { alert.beginSheetModal(for: window) } else { alert.runModal() }
    }
}

/// Keeps the save panel's format menu in step with the file type.
private final class PopupHandler: NSObject {
    let onChange: (Int) -> Void
    private static var current: PopupHandler?

    init(_ onChange: @escaping (Int) -> Void) {
        self.onChange = onChange
        super.init()
        Self.current = self
    }

    @objc func changed(_ sender: NSPopUpButton) { onChange(sender.indexOfSelectedItem) }
}

/// Resize Image: width and height in pixels, proportions kept unless unlocked, or a percentage.
private struct ResizeSheet: View {
    let natural: CGSize
    let done: (CGSize?) -> Void
    @State private var width: Int
    @State private var height: Int
    @State private var keepsProportions = true

    init(natural: CGSize, current: CGSize, done: @escaping (CGSize?) -> Void) {
        self.natural = natural
        self.done = done
        _width = State(initialValue: Int(current.width.rounded()))
        _height = State(initialValue: Int(current.height.rounded()))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Resize Image").font(.headline)
            Form {
                TextField("Width", value: Binding(get: { width }, set: { value in
                    width = max(1, value)
                    if keepsProportions { height = max(1, Int((Double(width) * natural.height / natural.width).rounded())) }
                }), format: .number)
                TextField("Height", value: Binding(get: { height }, set: { value in
                    height = max(1, value)
                    if keepsProportions { width = max(1, Int((Double(height) * natural.width / natural.height).rounded())) }
                }), format: .number)
                Toggle("Keep proportions", isOn: $keepsProportions)
            }
            HStack {
                ForEach([25, 50, 75, 100], id: \.self) { percent in
                    Button("\(percent) %") {
                        width = max(1, Int((natural.width * Double(percent) / 100).rounded()))
                        height = max(1, Int((natural.height * Double(percent) / 100).rounded()))
                    }
                }
            }
            Text("Original: \(Int(natural.width)) × \(Int(natural.height)) pixels")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { done(nil) }.keyboardShortcut(.cancelAction)
                Button("Resize") { done(CGSize(width: width, height: height)) }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 320)
    }
}
