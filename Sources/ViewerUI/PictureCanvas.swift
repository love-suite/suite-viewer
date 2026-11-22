import AppKit
import Combine
import PictureEditCore

/// The picture in the viewer's window, inside its zooming scroll view. Viewing, it shows the file
/// (animated pictures move) and lets the text in it be selected; editing, it draws the editable
/// version and handles the tools: drawing, selecting, moving and resizing shapes, typing text and
/// cropping. Its coordinates are points, one picture pixel per screen pixel at 100 %.
final class PictureCanvas: NSView, NSTextViewDelegate {
    let imageView = PassiveImageView()
    private let overlay = TextOverlay()

    /// Points per picture pixel.
    var pointsPerPixel: CGFloat = 0.5

    // MARK: Viewing: the text in the picture

    var recognized: RecognizedText = .empty { didSet { textSelection = nil; overlay.needsDisplay = true } }
    var textSelection: ClosedRange<Int>? { didSet { overlay.needsDisplay = true } }
    var showsAllText = false { didSet { overlay.needsDisplay = true } }
    var matches: [ClosedRange<Int>] = [] { didSet { overlay.needsDisplay = true } }
    var currentMatch: Int? { didSet { overlay.needsDisplay = true } }

    var selectedText: String? { textSelection.map { recognized.text(in: $0) } }

    // MARK: Editing

    private(set) var editor: PictureEditor?
    private var observation: AnyCancellable?
    /// Called when the canvas changes size (cropping, turning), so the window fits it again.
    var onResize: (() -> Void)?
    /// The crop being drawn, in canvas space, until it is applied.
    private(set) var cropDraft: CGRect?
    private var textEditor: NSTextView?
    private var editingShapeID: UUID?

    private enum Drag {
        case none
        case drawing(UUID, origin: CGPoint)
        case moving(start: CGPoint, originals: [UUID: Shape], duplicated: Bool)
        case resizing(Handle, original: Shape)
        case rubberBand(start: CGPoint, current: CGPoint)
        case cropNew(start: CGPoint)
        case cropMove(start: CGPoint, original: CGRect)
        case cropResize(Handle, original: CGRect)
        case selectingText(anchor: Int)
        case panning(start: NSPoint, origin: NSPoint)
    }

    private var drag = Drag.none

    override init(frame: NSRect) {
        super.init(frame: frame)
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.animates = true
        imageView.autoresizingMask = [.width, .height]
        overlay.canvas = self
        overlay.autoresizingMask = [.width, .height]
        addSubview(imageView)
        addSubview(overlay)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect, .cursorUpdate],
                                       owner: self))
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        if let textEditor, textEditor.frame.contains(convert(point, from: superview)) { return super.hitTest(point) }
        return frame.contains(point) ? self : nil
    }

    private var magnification: CGFloat { enclosingScrollView?.magnification ?? 1 }

    // MARK: Modes

    /// Shows the picture file.
    func showPicture(_ image: NSImage?, pixelSize: CGSize) {
        stopEditing()
        imageView.image = image
        imageView.isHidden = false
        recognized = .empty
        matches = []
        currentMatch = nil
        setFrameSize(NSSize(width: pixelSize.width * pointsPerPixel, height: pixelSize.height * pointsPerPixel))
        imageView.frame = bounds
        overlay.frame = bounds
    }

    func startEditing(_ editor: PictureEditor) {
        self.editor = editor
        imageView.isHidden = true
        textSelection = nil
        editor.onToolChange = { [weak self] old, new in
            guard let self else { return }
            if old == .crop { self.applyCrop() }
            if new == .crop { self.cropDraft = self.editor?.document.cropRect }
            self.editorDidChange()
        }
        if editor.tool == .crop { cropDraft = editor.document.cropRect }
        observation = editor.objectWillChange.sink { [weak self] in
            DispatchQueue.main.async { self?.editorDidChange() }
        }
        editorDidChange()
        window?.makeFirstResponder(self)
    }

    func stopEditing() {
        guard editor != nil else { return }
        endTextEditing()
        applyCrop()
        observation = nil
        editor?.onToolChange = nil
        editor = nil
        drag = .none
        imageView.isHidden = false
        needsDisplay = true
    }

    /// The part of the canvas shown: everything while cropping, the crop otherwise.
    private var displayRect: CGRect {
        guard let editor else { return CGRect(origin: .zero, size: bounds.size) }
        return editor.tool == .crop ? editor.document.canvasRect : editor.document.cropRect
    }

    private func editorDidChange() {
        guard let editor else { return }
        if editingShapeID != nil, editor.document.shape(editingShapeID!) == nil { endTextEditing(commit: false) }
        let size = NSSize(width: displayRect.width * pointsPerPixel, height: displayRect.height * pointsPerPixel)
        if size != frame.size {
            setFrameSize(size)
            imageView.frame = bounds
            overlay.frame = bounds
            onResize?()
        }
        updateCursor()
        needsDisplay = true
    }

    /// Applies the crop being drawn, as one history step.
    func applyCrop() {
        guard let editor, let draft = cropDraft else { return }
        cropDraft = nil
        if draft.integral != editor.document.cropRect.integral { editor.apply("Crop") { $0.setCrop(draft) } }
    }

    /// Starts the crop again from the document's (after a turn).
    func resetCropDraftToDocument() {
        guard let editor else { return }
        cropDraft = editor.tool == .crop ? editor.document.cropRect : nil
        needsDisplay = true
    }

    func resetCrop() {
        guard let editor else { return }
        cropDraft = editor.document.canvasRect
        needsDisplay = true
    }

    /// Fits the crop to the chosen proportions, around its centre.
    func cropAspectChanged() {
        guard let editor, var draft = cropDraft,
              let ratio = editor.cropAspect.ratio(for: editor.document.canvasSize, portrait: editor.cropPortrait) else { return }
        let center = CGPoint(x: draft.midX, y: draft.midY)
        var width = draft.width, height = width / ratio
        if height > draft.height { height = draft.height; width = height * ratio }
        draft = CGRect(x: center.x - width / 2, y: center.y - height / 2, width: width, height: height)
        cropDraft = fitInside(draft, editor.document.canvasRect)
        needsDisplay = true
    }

    // MARK: Coordinates

    func toCanvas(_ point: NSPoint) -> CGPoint {
        CGPoint(x: point.x / pointsPerPixel + displayRect.minX, y: point.y / pointsPerPixel + displayRect.minY)
    }

    func toView(_ point: CGPoint) -> NSPoint {
        NSPoint(x: (point.x - displayRect.minX) * pointsPerPixel, y: (point.y - displayRect.minY) * pointsPerPixel)
    }

    func toView(_ rect: CGRect) -> NSRect {
        let origin = toView(rect.origin)
        return NSRect(x: origin.x, y: origin.y, width: rect.width * pointsPerPixel, height: rect.height * pointsPerPixel)
    }

    /// The middle of what is visible, in canvas space: where pasted things go.
    var visibleCenter: CGPoint {
        let visible = visibleRect.isEmpty ? bounds : visibleRect
        return toCanvas(NSPoint(x: visible.midX, y: visible.midY))
    }

    /// A few screen points, in picture pixels.
    private var tolerance: Double { 6 / (magnification * pointsPerPixel) }
    private var handleRadius: CGFloat { 5 / magnification }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let editor, let context = NSGraphicsContext.current?.cgContext else { return }
        let document = editor.document
        let display = displayRect
        context.saveGState()
        context.scaleBy(x: pointsPerPixel, y: pointsPerPixel)
        context.translateBy(x: -display.minX, y: -display.minY)
        context.clip(to: display)
        context.interpolationQuality = .high
        // A copy of the picture about the size it shows at draws much faster than the full one.
        let screenScale = pointsPerPixel * magnification * (window?.backingScaleFactor ?? 2)
        let needed = Double(max(document.imageSize.width, document.imageSize.height)) * screenScale
        var side = 1024
        while Double(side) < needed * 1.1 && side < 16384 { side *= 2 }
        let base = editor.renderer.previewImage(document.adjustments, maxSide: side)
        editor.renderer.drawCanvas(document, in: context, hidden: editingShapeID.map { [$0] } ?? [], base: base)
        context.restoreGState()

        if editor.tool == .crop {
            drawCropOverlay()
            return
        }
        drawSelection(editor)
        if case .rubberBand(let start, let current) = drag {
            let rect = toView(CGRect(x: min(start.x, current.x), y: min(start.y, current.y),
                                     width: abs(current.x - start.x), height: abs(current.y - start.y)))
            NSColor.controlAccentColor.withAlphaComponent(0.15).setFill()
            rect.fill()
            NSColor.controlAccentColor.setStroke()
            let path = NSBezierPath(rect: rect)
            path.lineWidth = 1 / magnification
            path.stroke()
        }
    }

    private func drawSelection(_ editor: PictureEditor) {
        let shapes = editor.selection.compactMap { editor.document.shape($0) }
        let line = 1 / magnification
        for shape in shapes where !shape.kind.isSegment && shape.id != editingShapeID {
            let path = NSBezierPath(rect: toView(shape.bounds).insetBy(dx: -2 * line, dy: -2 * line))
            path.lineWidth = line
            path.setLineDash([4 * line, 3 * line], count: 2, phase: 0)
            NSColor.controlAccentColor.setStroke()
            path.stroke()
        }
        guard shapes.count == 1, let shape = shapes.first, shape.id != editingShapeID else { return }
        for handle in shape.handles { drawHandle(at: toView(shape.location(of: handle))) }
    }

    private func drawHandle(at point: NSPoint) {
        let r = handleRadius
        let path = NSBezierPath(ovalIn: NSRect(x: point.x - r, y: point.y - r, width: 2 * r, height: 2 * r))
        path.lineWidth = 1.5 / magnification
        NSColor.white.setFill()
        path.fill()
        NSColor.controlAccentColor.setStroke()
        path.stroke()
    }

    private func drawCropOverlay() {
        guard let draft = cropDraft else { return }
        let rect = toView(draft)
        let dim = NSBezierPath(rect: bounds)
        dim.append(NSBezierPath(rect: rect))
        dim.windingRule = .evenOdd
        NSColor.black.withAlphaComponent(0.55).setFill()
        dim.fill()
        let line = 1 / magnification
        NSColor.white.withAlphaComponent(0.5).setStroke()
        let thirds = NSBezierPath()
        for i in 1...2 {
            let x = rect.minX + rect.width * CGFloat(i) / 3, y = rect.minY + rect.height * CGFloat(i) / 3
            thirds.move(to: NSPoint(x: x, y: rect.minY)); thirds.line(to: NSPoint(x: x, y: rect.maxY))
            thirds.move(to: NSPoint(x: rect.minX, y: y)); thirds.line(to: NSPoint(x: rect.maxX, y: y))
        }
        thirds.lineWidth = line
        thirds.stroke()
        NSColor.white.setStroke()
        let border = NSBezierPath(rect: rect)
        border.lineWidth = 2 * line
        border.stroke()
        for handle in Self.cropHandles { drawHandle(at: toView(location(of: handle, in: draft))) }
    }

    private static let cropHandles: [Handle] = [.topLeft, .top, .topRight, .right, .bottomRight, .bottom, .bottomLeft, .left]

    private func location(of handle: Handle, in r: CGRect) -> CGPoint {
        Shape(kind: .rectangle, points: [r.origin, CGPoint(x: r.maxX, y: r.maxY)], style: ShapeStyle()).location(of: handle)
    }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        let viewPoint = convert(event.locationInWindow, from: nil)
        guard let editor else { return viewMouseDown(event, at: viewPoint) }
        if textEditor != nil {
            endTextEditing()
            if editor.tool == .text { return }
        }
        window?.makeFirstResponder(self)
        let p = toCanvas(viewPoint)
        let shift = event.modifierFlags.contains(.shift)
        let document = editor.document

        if editor.tool == .crop {
            guard let draft = cropDraft else { return }
            if let handle = Self.cropHandles.first(where: { isNear(viewPoint, location(of: $0, in: draft)) }) {
                drag = .cropResize(handle, original: draft)
            } else if draft.contains(p), draft.integral != editor.document.canvasRect.integral {
                // Inside a crop smaller than the picture: move it. Over the whole picture, draw a new one.
                drag = .cropMove(start: p, original: draft)
            } else {
                drag = .cropNew(start: p)
            }
            return
        }

        if event.clickCount == 2, let hit = document.hitTest(p, tolerance: tolerance), hit.kind == .text {
            editor.selectShape(hit.id)
            beginTextEditing(hit)
            return
        }
        // The selected shape's handles and the selected shapes themselves answer whatever the tool, so a
        // shape just drawn can be adjusted without switching tools.
        if editor.selection.count == 1, let id = editor.selection.first, let shape = document.shape(id),
           let handle = shape.handles.first(where: { isNear(viewPoint, shape.location(of: $0)) }) {
            drag = .resizing(handle, original: shape)
            return
        }
        if let hit = document.hitTest(p, tolerance: tolerance), editor.tool == .select || editor.selection.contains(hit.id) {
            if editor.tool == .select {
                if shift { editor.selectShape(hit.id, extending: true) }
                else if !editor.selection.contains(hit.id) { editor.selectShape(hit.id) }
            }
            var duplicated = false
            if event.modifierFlags.contains(.option) {
                // Option-drag leaves a copy behind, as in Preview and Keynote.
                editor.preview { doc in
                    for id in editor.selection {
                        guard let shape = doc.shape(id), let (l, _) = doc.locate(id) else { continue }
                        var copy = shape
                        copy.id = UUID()
                        if copy.kind == .step { copy.number = nil }
                        doc.add(copy, to: doc.layers[l].id)
                    }
                }
                duplicated = true
            }
            let originals = Dictionary(uniqueKeysWithValues: editor.selection.compactMap { id in
                editor.document.shape(id).map { (id, $0) }
            })
            drag = .moving(start: p, originals: originals, duplicated: duplicated)
            return
        }
        if editor.tool == .select {
            if !shift { editor.selection = [] }
            drag = .rubberBand(start: p, current: p)
            return
        }
        guard let kind = editor.tool.shapeKind else { return }
        editor.selection = []
        var shape = editor.newShape(kind, at: p)
        switch kind {
        case .text:
            let width = min(max(shape.style.fontSize * 12, 120), document.cropRect.maxX - p.x)
            let size = TextLayout.frameSize("", style: shape.style, width: max(width, shape.style.fontSize * 3))
            shape.points = [p, CGPoint(x: p.x + size.width, y: p.y + size.height)]
            editor.preview { $0.add(shape, to: editor.currentLayer) }
            editor.selection = [shape.id]
            beginTextEditing(editor.document.shape(shape.id) ?? shape)
            return
        case .step:
            let side = shape.style.fontSize * 2
            shape.points = [CGPoint(x: p.x - side / 2, y: p.y - side / 2), CGPoint(x: p.x + side / 2, y: p.y + side / 2)]
        case .pen, .highlighter:
            shape.points = [p]
        default: break
        }
        editor.preview { $0.add(shape, to: editor.currentLayer) }
        drag = .drawing(shape.id, origin: p)
    }

    override func mouseDragged(with event: NSEvent) {
        let viewPoint = convert(event.locationInWindow, from: nil)
        guard let editor else { return viewMouseDragged(event, at: viewPoint) }
        let p = toCanvas(viewPoint)
        let shift = event.modifierFlags.contains(.shift)
        switch drag {
        case .none, .selectingText, .panning:
            return
        case .drawing(let id, let origin):
            guard var shape = editor.document.shape(id) else { return }
            switch shape.kind {
            case .pen, .highlighter:
                if let last = shape.points.last, hypot(p.x - last.x, p.y - last.y) < 0.5 / magnification { return }
                shape.points.append(p)
            case .line, .arrow:
                shape.points[1] = shift ? Shape.snapAngle(from: origin, to: p) : p
            case .step:
                let side = shape.frame.width
                shape.points = [CGPoint(x: p.x - side / 2, y: p.y - side / 2), CGPoint(x: p.x + side / 2, y: p.y + side / 2)]
            default:
                shape.points[1] = shift ? Shape.square(from: origin, to: p) : p
            }
            editor.preview { $0.update(shape) }
        case .moving(let start, let originals, _):
            let offset = CGVector(dx: p.x - start.x, dy: p.y - start.y)
            editor.preview { doc in for shape in originals.values { doc.update(shape.moved(by: offset)) } }
        case .resizing(let handle, let original):
            var shape = original.resizing(handle, to: p, keepAspect: shift)
            if shape.kind == .text {
                let frame = shape.frame
                let size = TextLayout.frameSize(shape.text, style: shape.style, width: max(frame.width, shape.style.fontSize))
                shape.points = [frame.origin, CGPoint(x: frame.minX + size.width, y: frame.minY + size.height)]
            }
            editor.preview { $0.update(shape) }
        case .rubberBand(let start, _):
            drag = .rubberBand(start: start, current: p)
            let rect = CGRect(x: min(start.x, p.x), y: min(start.y, p.y), width: abs(p.x - start.x), height: abs(p.y - start.y))
            editor.selection = Set(editor.document.shapes(in: rect).map(\.id))
            needsDisplay = true
        case .cropNew(let start):
            cropDraft = constrainedCrop(from: start, to: p)
            needsDisplay = true
        case .cropMove(let start, let original):
            let moved = original.offsetBy(dx: p.x - start.x, dy: p.y - start.y)
            cropDraft = fitInside(moved, editor.document.canvasRect)
            needsDisplay = true
        case .cropResize(let handle, let original):
            var resized = Shape(kind: .rectangle, points: [original.origin, CGPoint(x: original.maxX, y: original.maxY)],
                                style: ShapeStyle())
                .resizing(handle, to: p, keepAspect: editor.cropAspect != .free || shift).frame
            if let ratio = editor.cropAspect.ratio(for: editor.document.canvasSize, portrait: editor.cropPortrait),
               resized.height > 0, abs(resized.width / resized.height - ratio) > 0.01 {
                resized.size.height = resized.width / ratio
            }
            cropDraft = resized.intersection(editor.document.canvasRect)
            needsDisplay = true
        }
        autoscroll(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        guard let editor else { drag = .none; return }
        let finished = drag
        drag = .none
        switch finished {
        case .drawing(let id, _):
            guard var shape = editor.document.shape(id) else { return }
            let tiny = shape.kind.isPath ? false
                : shape.kind == .step ? false
                : max(shape.bounds.width - shape.style.lineWidth, shape.bounds.height - shape.style.lineWidth) < tolerance
            if tiny {
                editor.preview { $0.remove([id]) }
                return
            }
            if shape.kind.isPath {
                shape.points = Shape.simplified(shape.points, spacing: max(0.5, editor.unit * 0.6))
                editor.preview { $0.update(shape) }
            }
            editor.commit(editor.tool.title)
            editor.selection = [id]
        case .moving(let start, let originals, let duplicated):
            let p = toCanvas(convert(event.locationInWindow, from: nil))
            if duplicated || hypot(p.x - start.x, p.y - start.y) > 0 {
                editor.commit(duplicated ? "Duplicate" : "Move")
            }
            if duplicated {
                // The copies stay where they were; the moved shapes are the originals, still selected.
                _ = originals
            }
        case .resizing:
            editor.commit("Resize")
        case .rubberBand:
            needsDisplay = true
        default:
            break
        }
    }

    private func isNear(_ viewPoint: NSPoint, _ canvasPoint: CGPoint) -> Bool {
        let p = toView(canvasPoint)
        return hypot(viewPoint.x - p.x, viewPoint.y - p.y) <= handleRadius * 1.8
    }

    private func constrainedCrop(from start: CGPoint, to p: CGPoint) -> CGRect {
        guard let editor else { return .null }
        var end = p
        if let ratio = editor.cropAspect.ratio(for: editor.document.canvasSize, portrait: editor.cropPortrait) {
            let width = abs(p.x - start.x)
            end.y = start.y + (p.y < start.y ? -1 : 1) * width / ratio
        }
        let rect = CGRect(x: min(start.x, end.x), y: min(start.y, end.y), width: abs(end.x - start.x), height: abs(end.y - start.y))
        return rect.intersection(editor.document.canvasRect)
    }

    private func fitInside(_ rect: CGRect, _ bounds: CGRect) -> CGRect {
        var rect = rect
        rect.size.width = min(rect.width, bounds.width)
        rect.size.height = min(rect.height, bounds.height)
        rect.origin.x = min(max(rect.minX, bounds.minX), bounds.maxX - rect.width)
        rect.origin.y = min(max(rect.minY, bounds.minY), bounds.maxY - rect.height)
        return rect
    }

    // MARK: Viewing: selecting text, panning

    private func normalized(_ point: NSPoint) -> CGPoint {
        CGPoint(x: point.x / max(bounds.width, 1), y: point.y / max(bounds.height, 1))
    }

    private func viewMouseDown(_ event: NSEvent, at point: NSPoint) {
        window?.makeFirstResponder(self)
        let n = normalized(point)
        if let word = recognized.word(at: n, tolerance: 0.004) {
            if event.clickCount >= 3 {
                textSelection = 0...(recognized.words.count - 1)
            } else if event.clickCount == 2 {
                let line = recognized.words[word].line
                let indices = recognized.words.indices.filter { recognized.words[$0].line == line }
                textSelection = indices.first!...indices.last!
            } else if event.modifierFlags.contains(.shift), let current = textSelection {
                textSelection = min(current.lowerBound, word)...max(current.upperBound, word)
            } else {
                textSelection = word...word
                drag = .selectingText(anchor: word)
            }
            return
        }
        textSelection = nil
        if let clip = enclosingScrollView?.contentView {
            drag = .panning(start: event.locationInWindow, origin: clip.bounds.origin)
        }
    }

    private func viewMouseDragged(_ event: NSEvent, at point: NSPoint) {
        switch drag {
        case .selectingText(let anchor):
            guard let word = recognized.nearestWord(to: normalized(point)) else { return }
            textSelection = min(anchor, word)...max(anchor, word)
            autoscroll(with: event)
        case .panning(let start, let origin):
            guard let scroll = enclosingScrollView else { return }
            let scale = scroll.magnification
            let dx = (event.locationInWindow.x - start.x) / scale, dy = (event.locationInWindow.y - start.y) / scale
            scroll.contentView.scroll(to: NSPoint(x: origin.x - dx, y: origin.y + dy))
            scroll.reflectScrolledClipView(scroll.contentView)
        default:
            break
        }
    }

    /// The boxes of words, in view points.
    func viewRects(for range: ClosedRange<Int>) -> [NSRect] {
        recognized.boxes(for: range).map {
            NSRect(x: $0.minX * bounds.width, y: $0.minY * bounds.height, width: $0.width * bounds.width,
                   height: $0.height * bounds.height)
        }
    }

    // MARK: Cursor

    override func mouseMoved(with event: NSEvent) { updateCursor(event) }
    override func cursorUpdate(with event: NSEvent) { updateCursor(event) }

    private func updateCursor(_ event: NSEvent? = nil) {
        guard let window, let location = event?.locationInWindow ?? Optional(window.mouseLocationOutsideOfEventStream)
        else { return }
        let point = convert(location, from: nil)
        guard bounds.contains(point), visibleRect.contains(point) else { return }
        guard let editor else {
            (recognized.word(at: normalized(point), tolerance: 0.004) != nil ? NSCursor.iBeam : NSCursor.arrow).set()
            return
        }
        let p = toCanvas(point)
        if editor.tool == .crop {
            (cropDraft?.contains(p) == true ? NSCursor.openHand : NSCursor.crosshair).set()
        } else if let hit = editor.document.hitTest(p, tolerance: tolerance),
                  editor.tool == .select || editor.selection.contains(hit.id) {
            NSCursor.openHand.set()
        } else if editor.tool == .text {
            NSCursor.iBeam.set()
        } else {
            (editor.tool == .select ? NSCursor.arrow : NSCursor.crosshair).set()
        }
    }

    // MARK: Typing text

    func beginTextEditing(_ shape: Shape) {
        endTextEditing()
        guard editor != nil else { return }
        editingShapeID = shape.id
        let style = shape.style
        let pad = TextLayout.padding(style)
        let view = NSTextView(frame: toView(shape.frame.insetBy(dx: pad, dy: pad)))
        view.isRichText = false
        view.allowsUndo = true
        view.importsGraphics = false
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.font = Self.font(for: style, scale: pointsPerPixel)
        view.textColor = NSColor(cgColor: style.stroke.cgColor)
        view.insertionPointColor = view.textColor ?? .labelColor
        view.drawsBackground = false
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.textContainer?.widthTracksTextView = true
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.string = shape.text
        view.delegate = self
        addSubview(view)
        textEditor = view
        window?.makeFirstResponder(view)
        view.selectAll(nil)
        needsDisplay = true
    }

    /// The font text shapes are drawn with (the system font, bold, unless one was picked).
    static func font(for style: ShapeStyle, scale: CGFloat) -> NSFont {
        let size = style.fontSize * scale
        if let name = style.fontName, let font = NSFont(name: name, size: size) { return font }
        return .boldSystemFont(ofSize: size)
    }

    func textDidChange(_ notification: Notification) {
        guard let view = textEditor, let manager = view.layoutManager, let container = view.textContainer else { return }
        manager.ensureLayout(for: container)
        let height = max(manager.usedRect(for: container).height, view.font?.pointSize ?? 12)
        if abs(view.frame.height - height) > 0.5 { view.setFrameSize(NSSize(width: view.frame.width, height: height)) }
    }

    func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(cancelOperation(_:)) {
            endTextEditing()
            window?.makeFirstResponder(self)
            return true
        }
        return false
    }

    var isEditingText: Bool { textEditor != nil }

    /// Puts the typed text into its shape; an empty text shape goes away.
    func endTextEditing(commit: Bool = true) {
        guard let view = textEditor, let id = editingShapeID else { return }
        let text = view.string
        view.removeFromSuperview()
        textEditor = nil
        editingShapeID = nil
        needsDisplay = true
        guard commit, let editor, var shape = editor.document.shape(id) else { return }
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            editor.selection.remove(id)
            editor.preview { $0.remove([id]) }
            editor.commit("Delete Text")
            return
        }
        shape.text = text
        let size = TextLayout.frameSize(text, style: shape.style, width: shape.frame.width)
        shape.points = [shape.frame.origin, CGPoint(x: shape.frame.minX + size.width, y: shape.frame.minY + size.height)]
        editor.preview { $0.update(shape) }
        editor.commit("Text")
    }

    // MARK: Right click

    var menuProvider: ((NSEvent, CGPoint?) -> NSMenu?)?

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        if let editor, editor.tool != .crop {
            let p = toCanvas(point)
            if let hit = editor.document.hitTest(p, tolerance: tolerance), !editor.selection.contains(hit.id) {
                editor.selectShape(hit.id)
            }
            return menuProvider?(event, p)
        }
        return menuProvider?(event, nil)
    }
}

/// The picture of the viewing mode; clicks go to the canvas.
final class PassiveImageView: NSImageView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Draws the found text over the picture: all of it when shown, search matches, the selection.
private final class TextOverlay: NSView {
    weak var canvas: PictureCanvas?

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard let canvas, canvas.editor == nil, !canvas.recognized.isEmpty else { return }
        let words = canvas.recognized.words
        func fill(_ rects: [NSRect], _ color: NSColor) {
            color.setFill()
            for rect in rects { NSBezierPath(roundedRect: rect.insetBy(dx: -2, dy: -1), xRadius: 3, yRadius: 3).fill() }
        }
        if canvas.showsAllText {
            NSColor.black.withAlphaComponent(0.35).setFill()
            bounds.fill()
            fill(canvas.viewRects(for: 0...(words.count - 1)), NSColor.white.withAlphaComponent(0.35))
        }
        for (index, match) in canvas.matches.enumerated() {
            fill(canvas.viewRects(for: match), index == canvas.currentMatch ? .systemOrange.withAlphaComponent(0.6)
                                                                             : .systemYellow.withAlphaComponent(0.45))
        }
        if let selection = canvas.textSelection {
            fill(canvas.viewRects(for: selection), NSColor.selectedTextBackgroundColor.withAlphaComponent(0.55))
        }
    }
}
