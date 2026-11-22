import AppKit
import Combine
import PictureEditCore
import UniformTypeIdentifiers

/// The editor's tools, Preview's Markup and Windows' Photos and Snipping Tool together. Each has a
/// one-letter key, as in drawing apps.
enum EditTool: String, CaseIterable, Identifiable {
    case select, pen, highlighter, rectangle, ellipse, line, arrow, text, step, blur, pixelate, redact, crop

    var id: String { rawValue }

    var shapeKind: Shape.Kind? {
        switch self {
        case .select, .crop: nil
        case .pen: .pen
        case .highlighter: .highlighter
        case .rectangle: .rectangle
        case .ellipse: .ellipse
        case .line: .line
        case .arrow: .arrow
        case .text: .text
        case .step: .step
        case .blur: .blur
        case .pixelate: .pixelate
        case .redact: .redact
        }
    }

    var title: String {
        switch self {
        case .select: UIL("Select")
        case .pen: UIL("Pen")
        case .highlighter: UIL("Highlighter")
        case .rectangle: UIL("Rectangle")
        case .ellipse: UIL("Ellipse")
        case .line: UIL("Line")
        case .arrow: UIL("Arrow")
        case .text: UIL("Text")
        case .step: UIL("Numbered Step")
        case .blur: UIL("Blur")
        case .pixelate: UIL("Pixelate")
        case .redact: UIL("Hide")
        case .crop: UIL("Crop and Rotate")
        }
    }

    var symbol: String {
        switch self {
        case .select: "cursorarrow"
        case .pen: "pencil.tip"
        case .highlighter: "highlighter"
        case .rectangle: "rectangle"
        case .ellipse: "circle"
        case .line: "line.diagonal"
        case .arrow: "arrow.up.right"
        case .text: "textformat"
        case .step: "1.circle"
        case .blur: "drop"
        case .pixelate: "checkerboard.rectangle"
        case .redact: "rectangle.fill"
        case .crop: "crop.rotate"
        }
    }

    /// The key that picks the tool while editing.
    var key: Character {
        switch self {
        case .select: "v"
        case .pen: "p"
        case .highlighter: "h"
        case .rectangle: "r"
        case .ellipse: "o"
        case .line: "l"
        case .arrow: "a"
        case .text: "t"
        case .step: "n"
        case .blur: "b"
        case .pixelate: "x"
        case .redact: "k"
        case .crop: "c"
        }
    }

    static func forKey(_ key: Character) -> EditTool? { allCases.first { $0.key == key } }
}

/// Crop proportions offered while cropping.
enum CropAspect: String, CaseIterable, Identifiable {
    case free, original, square, fourThree, threeTwo, sixteenNine

    var id: String { rawValue }

    var title: String {
        switch self {
        case .free: UIL("Free")
        case .original: UIL("Original")
        case .square: UIL("Square")
        case .fourThree: "4:3"
        case .threeTwo: "3:2"
        case .sixteenNine: "16:9"
        }
    }

    /// Width over height, nil for free; `size` is the picture's, for Original.
    func ratio(for size: CGSize, portrait: Bool) -> Double? {
        let ratio: Double? = switch self {
        case .free: nil
        case .original: size.width / max(size.height, 1)
        case .square: 1
        case .fourThree: 4.0 / 3
        case .threeTwo: 3.0 / 2
        case .sixteenNine: 16.0 / 9
        }
        guard let ratio, self != .original else { return ratio }
        return portrait ? 1 / ratio : ratio
    }
}

/// The editable version of the picture being edited, its history, and the editor's state (tool,
/// selection, styles). Live changes (a shape being dragged, a slider moving) change `document`
/// right away and become one history step when they end.
final class PictureEditor: ObservableObject {
    let url: URL
    let renderer: EditRenderer
    @Published private(set) var document: EditDocument
    @Published private(set) var history: EditHistory
    @Published var tool: EditTool = .select {
        didSet {
            guard tool != oldValue else { return }
            if tool != .select { selection = [] }
            onToolChange?(oldValue, tool)
        }
    }
    /// Told at once when the tool changes (the canvas applies a crop when cropping ends).
    var onToolChange: ((EditTool, EditTool) -> Void)?
    @Published var selection: Set<UUID> = []
    @Published var currentLayer: UUID
    @Published var cropAspect: CropAspect = .free
    @Published var cropPortrait = false
    /// Which side panel shows.
    @Published var panel: Panel = .adjust
    /// Styles for new shapes, by kind, remembered while the app runs.
    @Published private(set) var styles: [Shape.Kind: ShapeStyle] = [:]

    enum Panel: String, CaseIterable, Identifiable {
        case adjust = "Adjust", layers = "Layers", history = "History"
        var id: String { rawValue }
        var title: String { UIL(rawValue) }
    }

    private let store: EditStore
    private var record: EditStore.Record?
    private var assets: [String: Data]
    /// What the picture file shows now.
    private var saved: EditDocument
    private var saveTimer: Timer?
    /// Styles carried from picture to picture, in units of the picture's size.
    private static var rememberedStyles: [Shape.Kind: ShapeStyle] = [:]

    /// Opens the editable version of `url`: the one kept from before if the file is still what the
    /// viewer saved, else a fresh one.
    /// Where editable versions are kept; tests point it elsewhere.
    static var defaultStore = EditStore.standard

    init?(url: URL, store: EditStore = PictureEditor.defaultStore) {
        self.url = url
        self.store = store
        var history: EditHistory
        var assets: [String: Data] = [:]
        let original: CGImage
        if let record = store.record(for: url), let stored = try? store.load(record),
           let image = PictureFile.loadUpright(store.originalURL(record)) {
            self.record = record
            original = image
            history = stored.history
            assets = stored.assets
            saved = stored.saved ?? stored.history.current
        } else {
            guard let image = PictureFile.loadUpright(url) else { return nil }
            original = image
            history = EditHistory(EditDocument(imageSize: CGSize(width: image.width, height: image.height)))
            saved = history.current
        }
        renderer = EditRenderer(original: original)
        for (name, data) in assets { renderer.assets[name] = PictureFile.loadUpright(data) }
        self.history = history
        self.assets = assets
        document = history.current
        currentLayer = history.current.layers.last!.id
        let unit = ShapeStyle.unit(for: renderer.imageSize)
        for kind in Shape.Kind.allCases {
            var style = ShapeStyle.defaults(for: kind, pictureSize: renderer.imageSize)
            if let remembered = Self.rememberedStyles[kind] {
                style = remembered
                style.lineWidth = remembered.lineWidth * unit
                style.fontSize = remembered.fontSize * unit
            }
            styles[kind] = style
        }
    }

    var unit: Double { ShapeStyle.unit(for: renderer.imageSize) }

    /// The document differs from the picture file.
    var hasUnsavedChanges: Bool { document != saved }

    // MARK: Changing the document

    /// Changes the document without a history step yet (while dragging).
    func preview(_ change: (inout EditDocument) -> Void) {
        var doc = document
        change(&doc)
        if doc != document { document = doc }
    }

    /// Turns the live changes into a history step.
    func commit(_ name: String) {
        if history.record(document, name: name) {
            keepLayerValid()
            scheduleSave()
        }
    }

    /// One change, one history step.
    func apply(_ name: String, _ change: (inout EditDocument) -> Void) {
        preview(change)
        commit(name)
    }

    func undo() {
        if document != history.current { document = history.current; return }
        if let doc = history.undo() { document = doc; afterJump() }
    }

    func redo() {
        if let doc = history.redo() { document = doc; afterJump() }
    }

    func jump(to step: Int) {
        if let doc = history.jump(to: step) { document = doc; afterJump() }
    }

    private func afterJump() {
        selection = selection.filter { document.shape($0) != nil }
        keepLayerValid()
        scheduleSave()
    }

    private func keepLayerValid() {
        if document.layerIndex(currentLayer) == nil, let last = document.layers.last { currentLayer = last.id }
    }

    // MARK: Shapes

    func style(for kind: Shape.Kind) -> ShapeStyle {
        styles[kind] ?? ShapeStyle.defaults(for: kind, pictureSize: renderer.imageSize)
    }

    /// The style the bar shows: the selected shape's, else the current tool's.
    var shownStyle: ShapeStyle? {
        if let id = selection.first, let shape = document.shape(id) { return shape.style }
        return tool.shapeKind.map(style(for:))
    }

    /// The kind the style bar is about.
    var shownKind: Shape.Kind? {
        if let id = selection.first, let shape = document.shape(id) { return shape.kind }
        return tool.shapeKind
    }

    /// Restyles the selected shapes and the shapes drawn next.
    func changeStyle(_ name: String = "Change Style", live: Bool = false, _ change: (inout ShapeStyle) -> Void) {
        if let kind = shownKind {
            var style = style(for: kind)
            change(&style)
            styles[kind] = style
            var remembered = style
            remembered.lineWidth /= unit
            remembered.fontSize /= unit
            Self.rememberedStyles[kind] = remembered
        }
        guard !selection.isEmpty else { return }
        preview { doc in
            for id in selection {
                guard var shape = doc.shape(id) else { continue }
                change(&shape.style)
                if shape.kind == .text {
                    let size = TextLayout.frameSize(shape.text, style: shape.style, width: shape.frame.width)
                    shape.points = [shape.frame.origin, CGPoint(x: shape.frame.minX + size.width,
                                                                y: shape.frame.minY + size.height)]
                }
                doc.update(shape)
            }
        }
        if !live { commit(name) }
    }

    /// A new shape of the current tool's kind, not yet in the document.
    func newShape(_ kind: Shape.Kind, at point: CGPoint) -> Shape {
        Shape(kind: kind, points: [point, point], style: style(for: kind))
    }

    func deleteSelection() {
        guard !selection.isEmpty else { return }
        let ids = selection
        selection = []
        apply("Delete") { $0.remove(ids) }
    }

    func duplicateSelection() {
        let offset = CGVector(dx: unit * 12, dy: unit * 12)
        var copies: Set<UUID> = []
        apply("Duplicate") { doc in
            for id in selection {
                guard let shape = doc.shape(id), let (l, _) = doc.locate(id) else { continue }
                var copy = shape.moved(by: offset)
                copy.id = UUID()
                if copy.kind == .step { copy.number = nil }
                doc.add(copy, to: doc.layers[l].id)
                copies.insert(copy.id)
            }
        }
        selection = copies
    }

    func nudgeSelection(by offset: CGVector) {
        guard !selection.isEmpty else { return }
        apply("Move") { doc in
            for id in selection { if let shape = doc.shape(id) { doc.update(shape.moved(by: offset)) } }
        }
    }

    func arrangeSelection(_ order: EditDocument.Order) {
        apply("Arrange") { doc in for id in selection { doc.arrange(id, order) } }
    }

    func selectAll() {
        tool = .select
        selection = Set(document.layers.filter(\.isVisible).flatMap(\.shapes).map(\.id))
    }

    /// Shapes copied inside the editor, as JSON, with the pictures they show.
    static let shapesType = NSPasteboard.PasteboardType("local.suite.viewer.shapes")

    private struct Clip: Codable { var shapes: [Shape]; var assets: [String: Data] }

    func copySelection(to pasteboard: NSPasteboard = .general) -> Bool {
        let shapes = document.allShapes.filter { selection.contains($0.id) }
        guard !shapes.isEmpty else { return false }
        let clip = Clip(shapes: shapes, assets: assets.filter { name, _ in shapes.contains { $0.asset == name } })
        guard let data = try? JSONEncoder().encode(clip) else { return false }
        pasteboard.clearContents()
        pasteboard.setData(data, forType: Self.shapesType)
        if let text = shapes.first(where: { $0.kind == .text })?.text { pasteboard.setString(text, forType: .string) }
        return true
    }

    /// Pastes shapes copied in the editor, a picture (as a picture shape) or text (as a text shape).
    func paste(from pasteboard: NSPasteboard = .general, center: CGPoint) {
        if let data = pasteboard.data(forType: Self.shapesType), let clip = try? JSONDecoder().decode(Clip.self, from: data) {
            for (name, data) in clip.assets where assets[name] == nil { addAsset(data, named: name) }
            var pasted: Set<UUID> = []
            apply("Paste") { doc in
                for shape in clip.shapes {
                    var copy = shape.moved(by: CGVector(dx: unit * 12, dy: unit * 12))
                    copy.id = UUID()
                    doc.add(copy, to: currentLayer)
                    pasted.insert(copy.id)
                }
            }
            tool = .select
            selection = pasted
        } else if let image = NSImage(pasteboard: pasteboard) {
            insertPicture(image, center: center)
        } else if let text = pasteboard.string(forType: .string), !text.isEmpty {
            var shape = newShape(.text, at: center)
            shape.text = text
            let size = TextLayout.frameSize(text, style: shape.style, width: min(document.cropRect.width * 0.6, shape.style.fontSize * 20))
            shape.points = [CGPoint(x: center.x - size.width / 2, y: center.y - size.height / 2),
                            CGPoint(x: center.x + size.width / 2, y: center.y + size.height / 2)]
            apply("Paste") { $0.add(shape, to: currentLayer) }
            tool = .select
            selection = [shape.id]
        }
    }

    /// Places a picture on top, at most half the visible part's size.
    func insertPicture(_ image: NSImage, center: CGPoint) {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let data = PictureFile.encode(cgImage, as: .png) else { return }
        let name = UUID().uuidString
        addAsset(data, named: name)
        let room = document.cropRect.size
        var size = CGSize(width: cgImage.width, height: cgImage.height)
        let scale = min(1, room.width / 2 / size.width, room.height / 2 / size.height)
        size = CGSize(width: size.width * scale, height: size.height * scale)
        let shape = Shape(kind: .picture, points: [CGPoint(x: center.x - size.width / 2, y: center.y - size.height / 2),
                                                   CGPoint(x: center.x + size.width / 2, y: center.y + size.height / 2)],
                          style: ShapeStyle(), asset: name)
        apply("Insert Picture") { $0.add(shape, to: currentLayer) }
        tool = .select
        selection = [shape.id]
    }

    private func addAsset(_ data: Data, named name: String) {
        assets[name] = data
        renderer.assets[name] = PictureFile.loadUpright(data)
    }

    // MARK: Layers

    func addLayer() {
        var id = currentLayer
        apply("New Layer") { id = $0.addLayer(above: currentLayer) }
        currentLayer = id
    }

    func removeLayer(_ id: UUID) { apply("Delete Layer") { $0.removeLayer(id) } }

    func mergeDown(_ id: UUID) {
        var merged: UUID?
        apply("Merge Layers") { merged = $0.mergeDown(id) }
        if let merged { currentLayer = merged }
    }

    func moveLayer(_ id: UUID, by offset: Int) { apply("Move Layer") { $0.moveLayer(id, by: offset) } }

    /// Shapes of a selection move to the current layer when it is picked; clicking a shape picks its layer.
    func selectShape(_ id: UUID?, extending: Bool = false) {
        guard let id else { if !extending { selection = [] }; return }
        if extending {
            if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
        } else {
            selection = [id]
        }
        if let (l, _) = document.locate(id) { currentLayer = document.layers[l].id }
    }

    // MARK: Saving

    /// Keeps the editable version in the store a moment after each change.
    private func scheduleSave() {
        saveTimer?.invalidate()
        saveTimer = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: false) { [weak self] _ in self?.saveEdits() }
    }

    /// Writes the editable version to the store (the picture file is left alone).
    func saveEdits() {
        saveTimer?.invalidate()
        saveTimer = nil
        guard history.steps.count > 1 || record != nil else { return }
        do {
            let record = try self.record ?? store.create(for: url)
            self.record = record
            try store.save(StoredEdits(history: history, assets: assets, saved: saved), for: record)
        } catch {
            NSLog("Viewer: can't keep the edits of \(url.path): \(error)")
        }
    }

    /// The flattened picture.
    func flattened() -> CGImage? { renderer.render(document) }

    /// Whether Save can write into the file itself (an animated or unusual format can't).
    var canSaveInPlace: Bool { PictureFile.writableType(of: url) != nil }

    /// Writes what the editor shows into the picture file. The original stays in the store, so Revert
    /// to Original and the history still work afterwards.
    func saveToFile() throws {
        guard hasUnsavedChanges else { return }
        if record == nil { record = try store.create(for: url) }
        guard let record else { return }
        if document.isUnedited {
            try PictureFile.write(Data(contentsOf: store.originalURL(record)), to: url)
        } else {
            guard let type = PictureFile.writableType(of: url) else { throw ViewerError.cantWrite(url.pathExtension) }
            guard let image = flattened(), let data = PictureFile.encode(image, as: type, metadataFrom: store.originalURL(record))
            else { throw ViewerError.cantRender }
            try PictureFile.write(data, to: url)
        }
        self.record = try store.fileWasWritten(url, record: record)
        saved = document
        objectWillChange.send()
        saveEdits()
    }

    /// Writes the flattened picture to another file.
    func saveCopy(to destination: URL, as type: UTType) throws {
        guard let image = flattened(), let data = PictureFile.encode(image, as: type, metadataFrom: url)
        else { throw ViewerError.cantRender }
        try data.write(to: destination, options: .atomic)
    }

    /// Back to the picture as it first was, as a step that can be undone.
    func revertToOriginal() {
        selection = []
        apply("Revert to Original") { doc in doc = EditDocument(imageSize: renderer.imageSize) }
    }

    var isEdited: Bool { !document.isUnedited }
    var hasHistory: Bool { history.steps.count > 1 }
}

enum ViewerError: LocalizedError {
    case cantWrite(String)
    case cantRender

    var errorDescription: String? {
        switch self {
        case .cantWrite(let ext):
            String(format: UIL("Pictures of this type (%@) can't be saved in place. Use Save as Copy."), ext.uppercased())
        case .cantRender: UIL("The picture couldn't be drawn.")
        }
    }
}
