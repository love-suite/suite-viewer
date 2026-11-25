import AppKit
import PDFKit
import SuiteFilesUI

private final class PDFWindow: NSWindow {
    var keyHandler: ((NSEvent) -> Bool)?
    override func keyDown(with event: NSEvent) {
        if keyHandler?(event) != true { super.keyDown(with: event) }
    }
}

final class PDFViewerController: NSWindowController, NSWindowDelegate, NSToolbarDelegate, NSSearchFieldDelegate {
    private var url: URL?
    private let pdfView = PDFView()
    private let thumbnailView = PDFThumbnailView()
    private let split = NSSplitView()
    private let searchBar = NSView()
    private let searchField = NSSearchField()
    private var searchResults: [PDFSelection] = []
    private var searchIndex = 0
    private var showingThumbnails = false
    private var thumbnailWidth: CGFloat = 120
    private let pageLabel = NSTextField(labelWithString: "")

    private static let toolbarItems: [NSToolbarItem.Identifier] = [
        .init("previousPage"), .init("pageLabel"), .init("nextPage"), .flexibleSpace,
        .init("zoomOut"), .init("fit"), .init("zoomIn"), .flexibleSpace,
        .init("thumbnails"), .init("trash"), .init("preview"),
    ]

    private lazy var pageLabelItem: NSToolbarItem = {
        let item = NSToolbarItem(itemIdentifier: .init("pageLabel"))
        pageLabel.alignment = .center
        pageLabel.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        pageLabel.textColor = .labelColor
        pageLabel.widthAnchor.constraint(equalToConstant: 80).isActive = true
        item.view = pageLabel
        return item
    }()

    init() {
        let window = PDFWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 700),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 400, height: 300)
        window.toolbarStyle = .unified
        window.tabbingMode = .disallowed
        window.setFrameAutosaveName("PDFViewer")
        super.init(window: window)
        window.delegate = self
        window.keyHandler = { [weak self] in self?.handleKey($0) ?? false }

        pdfView.displayMode = .singlePageContinuous
        pdfView.autoScales = true
        pdfView.backgroundColor = .textBackgroundColor

        thumbnailView.pdfView = pdfView
        thumbnailView.thumbnailSize = NSSize(width: 70, height: 90)
        thumbnailView.backgroundColor = .controlBackgroundColor
        thumbnailView.isHidden = true

        split.isVertical = true
        split.dividerStyle = .thin
        split.addArrangedSubview(thumbnailView)
        split.addArrangedSubview(pdfView)

        setupSearchBar()

        let container = NSView()
        [split, searchBar].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview($0)
        }
        NSLayoutConstraint.activate([
            split.topAnchor.constraint(equalTo: container.topAnchor),
            split.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            split.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            split.bottomAnchor.constraint(equalTo: searchBar.topAnchor),
            searchBar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            searchBar.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            searchBar.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        window.contentView = container

        NotificationCenter.default.addObserver(self, selector: #selector(pageChanged),
                                               name: .PDFViewPageChanged, object: pdfView)

        let toolbar = NSToolbar(identifier: "PDFViewer")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        window.toolbar = toolbar
        if window.frame.origin == .zero { window.center() }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private func setupSearchBar() {
        let border = NSView()
        border.wantsLayer = true
        border.layer?.backgroundColor = NSColor.separatorColor.cgColor

        searchField.placeholderString = UIL("Find in document")
        searchField.delegate = self

        let prev = NSButton(image: NSImage(systemSymbolName: "chevron.up",
                                           accessibilityDescription: UIL("Previous result"))!,
                            target: self, action: #selector(previousMatch))
        prev.bezelStyle = .accessoryBarAction
        prev.isBordered = false

        let next = NSButton(image: NSImage(systemSymbolName: "chevron.down",
                                           accessibilityDescription: UIL("Next result"))!,
                            target: self, action: #selector(nextMatch))
        next.bezelStyle = .accessoryBarAction
        next.isBordered = false

        let close = NSButton(image: NSImage(systemSymbolName: "xmark.circle.fill",
                                            accessibilityDescription: UIL("Close"))!,
                             target: self, action: #selector(hideSearch))
        close.bezelStyle = .accessoryBarAction
        close.isBordered = false

        [border, searchField, prev, next, close].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            searchBar.addSubview($0)
        }
        NSLayoutConstraint.activate([
            border.topAnchor.constraint(equalTo: searchBar.topAnchor),
            border.leadingAnchor.constraint(equalTo: searchBar.leadingAnchor),
            border.trailingAnchor.constraint(equalTo: searchBar.trailingAnchor),
            border.heightAnchor.constraint(equalToConstant: 0.5),
            searchField.leadingAnchor.constraint(equalTo: searchBar.leadingAnchor, constant: 8),
            searchField.centerYAnchor.constraint(equalTo: searchBar.centerYAnchor),
            searchField.trailingAnchor.constraint(equalTo: prev.leadingAnchor, constant: -8),
            prev.centerYAnchor.constraint(equalTo: searchBar.centerYAnchor),
            prev.trailingAnchor.constraint(equalTo: next.leadingAnchor, constant: -4),
            next.centerYAnchor.constraint(equalTo: searchBar.centerYAnchor),
            next.trailingAnchor.constraint(equalTo: close.leadingAnchor, constant: -4),
            close.centerYAnchor.constraint(equalTo: searchBar.centerYAnchor),
            close.trailingAnchor.constraint(equalTo: searchBar.trailingAnchor, constant: -8),
            searchBar.heightAnchor.constraint(equalToConstant: 36),
        ])
        searchBar.isHidden = true
    }

    func show(_ url: URL) {
        self.url = url
        pdfView.document = PDFDocument(url: url)
        window?.title = url.lastPathComponent
        window?.representedURL = url
        updatePageLabel()
    }

    @objc private func pageChanged() { updatePageLabel() }

    private func updatePageLabel() {
        guard let doc = pdfView.document else { pageLabel.stringValue = ""; return }
        let n = pdfView.currentPage.flatMap { doc.index(for: $0) }.map { $0 + 1 } ?? 1
        pageLabel.stringValue = "\(n) / \(doc.pageCount)"
    }

    @objc private func previousPage() { pdfView.goToPreviousPage(nil) }
    @objc private func nextPage() { pdfView.goToNextPage(nil) }
    @objc private func previous() { pdfView.goToPreviousPage(nil) }
    @objc private func next() { pdfView.goToNextPage(nil) }
    @objc private func zoomIn() { pdfView.zoomIn(nil) }
    @objc private func zoomOut() { pdfView.zoomOut(nil) }
    @objc private func fit() { pdfView.autoScales = true }

    @objc private func toggleThumbnails() {
        showingThumbnails.toggle()
        if showingThumbnails {
            thumbnailView.isHidden = false
            split.setPosition(thumbnailWidth, ofDividerAt: 0)
        } else {
            thumbnailWidth = split.subviews[0].frame.width
            thumbnailView.isHidden = true
        }
    }

    @objc private func trash() {
        guard let url else { return }
        PictureViewer.moveToTrash(url)
        if !FileManager.default.fileExists(atPath: url.path) { window?.close() }
    }

    @objc private func openInPreview() {
        guard let url,
              let preview = NSWorkspace.shared.urlForApplication(
                  withBundleIdentifier: "com.apple.Preview") else { return }
        NSWorkspace.shared.open([url], withApplicationAt: preview, configuration: NSWorkspace.OpenConfiguration())
    }

    @objc func find(_ sender: Any?) {
        searchBar.isHidden = false
        window?.makeFirstResponder(searchField)
    }

    @objc private func hideSearch() {
        searchBar.isHidden = true
        pdfView.clearSelection()
        searchResults = []
        searchField.stringValue = ""
        window?.makeFirstResponder(pdfView)
    }

    func controlTextDidChange(_ obj: Notification) {
        guard obj.object as? NSSearchField === searchField else { return }
        performSearch(query: searchField.stringValue)
    }

    private func performSearch(query: String) {
        pdfView.clearSelection()
        guard let doc = pdfView.document, !query.isEmpty else { searchResults = []; return }
        searchResults = doc.findString(query, withOptions: .caseInsensitive)
        searchIndex = 0
        showResult(at: 0)
    }

    @objc private func nextMatch() {
        guard !searchResults.isEmpty else { return }
        searchIndex = (searchIndex + 1) % searchResults.count
        showResult(at: searchIndex)
    }

    @objc private func previousMatch() {
        guard !searchResults.isEmpty else { return }
        searchIndex = (searchIndex - 1 + searchResults.count) % searchResults.count
        showResult(at: searchIndex)
    }

    private func showResult(at index: Int) {
        guard index < searchResults.count else { return }
        let sel = searchResults[index]
        pdfView.go(to: sel)
        pdfView.setCurrentSelection(sel, animate: true)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.insertNewline(_:)):
            nextMatch()
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            hideSearch()
            return true
        default:
            return false
        }
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .control, .option])
        switch (event.charactersIgnoringModifiers, flags) {
        case ("f", .command): find(nil); return true
        case ("\u{1B}", []):
            if !searchBar.isHidden { hideSearch(); return true }
            if window?.styleMask.contains(.fullScreen) == true { window?.toggleFullScreen(nil); return true }
        default: break
        }
        return false
    }

    // MARK: Toolbar

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { Self.toolbarItems }
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { Self.toolbarItems }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier itemID: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        if itemID.rawValue == "pageLabel" { return pageLabelItem }
        let specs: [String: (String, String, Selector)] = [
            "previousPage": ("chevron.left", UIL("Previous Page"), #selector(previousPage)),
            "nextPage": ("chevron.right", UIL("Next Page"), #selector(nextPage)),
            "zoomOut": ("minus.magnifyingglass", UIL("Zoom Out"), #selector(zoomOut)),
            "fit": ("arrow.up.left.and.arrow.down.right", UIL("Fit to Window"), #selector(fit)),
            "zoomIn": ("plus.magnifyingglass", UIL("Zoom In"), #selector(zoomIn)),
            "thumbnails": ("sidebar.left", UIL("Thumbnails"), #selector(toggleThumbnails)),
            "trash": ("trash", UIL("Move to Trash"), #selector(trash)),
            "preview": ("square.and.pencil", UIL("Open in Preview"), #selector(openInPreview)),
        ]
        guard let (symbol, label, action) = specs[itemID.rawValue] else { return nil }
        let item = NSToolbarItem(itemIdentifier: itemID)
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        item.label = label
        item.toolTip = label
        item.target = self
        item.action = action
        item.isBordered = true
        return item
    }
}
