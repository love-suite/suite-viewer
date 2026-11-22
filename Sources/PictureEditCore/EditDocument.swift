import CoreGraphics
import Foundation

// The editable version of a picture: everything the viewer's editor changes, kept apart from the
// picture's pixels so it stays editable (shapes move, restyle, layers reorder) until it is flattened
// into a plain picture. All coordinates are picture pixels with the origin at the top left, in the
// "canvas" space: the picture once rotated and flipped, before cropping.

/// A colour as red, green, blue and alpha between 0 and 1, written "#RRGGBBAA" in the edits file.
public struct RGBA: Codable, Hashable, Sendable {
    public var red: Double, green: Double, blue: Double, alpha: Double

    /// Components are kept to 1/255 steps, what the file can write, so a colour reads back equal.
    public init(_ red: Double, _ green: Double, _ blue: Double, _ alpha: Double = 1) {
        func step(_ value: Double) -> Double { (min(max(value, 0), 1) * 255).rounded() / 255 }
        self.red = step(red); self.green = step(green); self.blue = step(blue); self.alpha = step(alpha)
    }

    public init?(hex: String) {
        var text = hex.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("#") { text.removeFirst() }
        if text.count == 6 { text += "FF" }
        guard text.count == 8, let value = UInt32(text, radix: 16) else { return nil }
        func part(_ shift: UInt32) -> Double { Double((value >> shift) & 0xFF) / 255 }
        self.init(part(24), part(16), part(8), part(0))
    }

    public var hex: String {
        func part(_ value: Double) -> String {
            String(format: "%02X", Int((min(max(value, 0), 1) * 255).rounded()))
        }
        return "#" + part(red) + part(green) + part(blue) + part(alpha)
    }

    public func withAlpha(_ alpha: Double) -> RGBA { RGBA(red, green, blue, alpha) }

    public var cgColor: CGColor { CGColor(srgbRed: red, green: green, blue: blue, alpha: alpha) }

    public init(from decoder: Decoder) throws {
        let text = try decoder.singleValueContainer().decode(String.self)
        guard let color = RGBA(hex: text) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Bad colour \(text)"))
        }
        self = color
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(hex)
    }

    public static let black = RGBA(0, 0, 0)
    public static let white = RGBA(1, 1, 1)
    public static let red = RGBA(1, 0.231, 0.188)
    public static let orange = RGBA(1, 0.584, 0)
    public static let yellow = RGBA(1, 0.8, 0)
    public static let green = RGBA(0.204, 0.78, 0.349)
    public static let blue = RGBA(0, 0.478, 1)
    public static let purple = RGBA(0.686, 0.322, 0.871)
    /// The colours offered first, as in Preview's and the Snipping Tool's palettes.
    public static let palette: [RGBA] = [.red, .orange, .yellow, .green, .blue, .purple, .black, .white]
}

/// How a shape looks. Sizes are picture pixels.
public struct ShapeStyle: Codable, Equatable, Sendable {
    public var stroke: RGBA = .red
    public var fill: RGBA?
    public var lineWidth: Double = 6
    public var opacity: Double = 1
    public var fontSize: Double = 48
    /// A PostScript font name; nil is the system font.
    public var fontName: String?
    public var dashed = false
    public var shadow = false
    /// Arrows: a head at the start as well as at the end.
    public var doubleHeaded = false
    public var cornerRadius: Double = 0

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case stroke, fill, lineWidth, opacity, fontSize, fontName, dashed, shadow, doubleHeaded, cornerRadius
    }

    // Missing keys take their defaults, so older and newer edits files both open.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        stroke = try c.decodeIfPresent(RGBA.self, forKey: .stroke) ?? stroke
        fill = try c.decodeIfPresent(RGBA.self, forKey: .fill)
        lineWidth = try c.decodeIfPresent(Double.self, forKey: .lineWidth) ?? lineWidth
        opacity = try c.decodeIfPresent(Double.self, forKey: .opacity) ?? opacity
        fontSize = try c.decodeIfPresent(Double.self, forKey: .fontSize) ?? fontSize
        fontName = try c.decodeIfPresent(String.self, forKey: .fontName)
        dashed = try c.decodeIfPresent(Bool.self, forKey: .dashed) ?? false
        shadow = try c.decodeIfPresent(Bool.self, forKey: .shadow) ?? false
        doubleHeaded = try c.decodeIfPresent(Bool.self, forKey: .doubleHeaded) ?? false
        cornerRadius = try c.decodeIfPresent(Double.self, forKey: .cornerRadius) ?? 0
    }

    /// The size unit for a picture: line widths and text sizes scale with the picture, so an arrow drawn
    /// on a large photo isn't a hairline and one drawn on a small screenshot isn't a bar.
    public static func unit(for size: CGSize) -> Double {
        max(1, (max(size.width, size.height) / 500).rounded(.toNearestOrAwayFromZero))
    }

    /// A shape's starting style on a picture of `size`.
    public static func defaults(for kind: Shape.Kind, pictureSize size: CGSize) -> ShapeStyle {
        let unit = unit(for: size)
        var style = ShapeStyle()
        style.lineWidth = 3 * unit
        style.fontSize = 18 * unit
        switch kind {
        case .highlighter:
            style.stroke = .yellow
            style.lineWidth = 14 * unit
        case .redact:
            style.stroke = .black
        case .step:
            style.fontSize = 14 * unit
        default: break
        }
        return style
    }
}

/// One annotation. `points` holds two corners for framed kinds, the two ends for lines and arrows, and
/// the whole path for the pen and the highlighter.
public struct Shape: Codable, Equatable, Identifiable, Sendable {
    public enum Kind: String, Codable, CaseIterable, Sendable {
        case rectangle, ellipse, line, arrow, pen, highlighter, text, step, blur, pixelate, redact, picture

        /// Drawn as a path through all its points.
        public var isPath: Bool { self == .pen || self == .highlighter }
        /// Defined by its two ends.
        public var isSegment: Bool { self == .line || self == .arrow }
        /// Stays upright and keeps its size when the picture is rotated or flipped: text stays readable.
        public var staysUpright: Bool { self == .text || self == .step || self == .picture }
        /// Hides what is under it.
        public var isMask: Bool { self == .blur || self == .pixelate || self == .redact }
    }

    public var id: UUID
    public var kind: Kind
    public var points: [CGPoint]
    public var style: ShapeStyle
    /// Text shapes: their text.
    public var text: String
    /// Picture shapes: the asset they show.
    public var asset: String?
    /// Step markers: their number.
    public var number: Int?

    public init(id: UUID = UUID(), kind: Kind, points: [CGPoint], style: ShapeStyle, text: String = "",
                asset: String? = nil, number: Int? = nil) {
        self.id = id; self.kind = kind; self.points = points; self.style = style; self.text = text
        self.asset = asset; self.number = number
    }

    private enum CodingKeys: String, CodingKey { case id, kind, points, style, text, asset, number }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        kind = try c.decode(Kind.self, forKey: .kind)
        points = try c.decode([CGPoint].self, forKey: .points)
        style = try c.decodeIfPresent(ShapeStyle.self, forKey: .style) ?? ShapeStyle()
        text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
        asset = try c.decodeIfPresent(String.self, forKey: .asset)
        number = try c.decodeIfPresent(Int.self, forKey: .number)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(kind, forKey: .kind)
        try c.encode(points, forKey: .points)
        try c.encode(style, forKey: .style)
        if !text.isEmpty { try c.encode(text, forKey: .text) }
        try c.encodeIfPresent(asset, forKey: .asset)
        try c.encodeIfPresent(number, forKey: .number)
    }
}

/// How a layer mixes with what is under it.
public enum BlendMode: String, Codable, CaseIterable, Sendable {
    case normal, multiply, screen, overlay, darken, lighten, difference

    public var title: String { rawValue.prefix(1).uppercased() + rawValue.dropFirst() }

    public var cgBlendMode: CGBlendMode {
        switch self {
        case .normal: .normal
        case .multiply: .multiply
        case .screen: .screen
        case .overlay: .overlay
        case .darken: .darken
        case .lighten: .lighten
        case .difference: .difference
        }
    }
}

/// A group of shapes drawn together, above the layers before it.
public struct Layer: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var isVisible: Bool
    public var opacity: Double
    public var blend: BlendMode
    public var shapes: [Shape]

    public init(id: UUID = UUID(), name: String, isVisible: Bool = true, opacity: Double = 1,
                blend: BlendMode = .normal, shapes: [Shape] = []) {
        self.id = id; self.name = name; self.isVisible = isVisible; self.opacity = opacity; self.blend = blend
        self.shapes = shapes
    }
}

/// Light and colour, applied to the picture under the shapes.
public struct Adjustments: Codable, Equatable, Sendable {
    public enum Filter: String, Codable, CaseIterable, Sendable {
        case none, vivid, mono, noir, tonal, chrome, fade, instant, process, transfer

        public var title: String { self == .none ? "Original" : rawValue.prefix(1).uppercased() + rawValue.dropFirst() }
    }

    /// Each between -1 and 1, 0 leaving the picture as it is.
    public var exposure = 0.0, brightness = 0.0, contrast = 0.0, highlights = 0.0, shadows = 0.0
    public var saturation = 0.0, warmth = 0.0, tint = 0.0
    /// Between 0 and 1.
    public var sharpness = 0.0, vignette = 0.0
    /// The system's automatic enhancement, as Photos' magic wand.
    public var autoEnhance = false
    public var filter = Filter.none

    public init() {}

    public var isIdentity: Bool { self == Adjustments() }

    private enum CodingKeys: String, CodingKey {
        case exposure, brightness, contrast, highlights, shadows, saturation, warmth, tint, sharpness, vignette,
             autoEnhance, filter
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func value(_ key: CodingKeys) throws -> Double { try c.decodeIfPresent(Double.self, forKey: key) ?? 0 }
        exposure = try value(.exposure); brightness = try value(.brightness); contrast = try value(.contrast)
        highlights = try value(.highlights); shadows = try value(.shadows); saturation = try value(.saturation)
        warmth = try value(.warmth); tint = try value(.tint); sharpness = try value(.sharpness)
        vignette = try value(.vignette)
        autoEnhance = try c.decodeIfPresent(Bool.self, forKey: .autoEnhance) ?? false
        filter = try c.decodeIfPresent(Filter.self, forKey: .filter) ?? .none
    }
}

/// The editable version of one picture.
public struct EditDocument: Codable, Equatable, Sendable {
    /// The original picture's size in pixels, once its own orientation (EXIF) is applied.
    public var imageSize: CGSize
    /// Clockwise quarter turns, applied after `flipped`.
    public var quarterTurns: Int
    /// Mirrored left to right, before turning.
    public var flipped: Bool
    /// The part kept, in canvas space; nil keeps everything.
    public var crop: CGRect?
    /// The saved picture's size, when resized; nil keeps the cropped size.
    public var outputSize: CGSize?
    public var adjustments: Adjustments
    /// From the bottom of the stack to the top.
    public var layers: [Layer]

    public init(imageSize: CGSize) {
        self.imageSize = imageSize
        quarterTurns = 0
        flipped = false
        adjustments = Adjustments()
        layers = [Layer(name: "Layer 1")]
    }

    /// Nothing changed: what the editor would save is the original picture.
    public var isUnedited: Bool {
        quarterTurns == 0 && !flipped && crop == nil && outputSize == nil && adjustments.isIdentity
            && layers.allSatisfy { $0.shapes.isEmpty }
    }

    public var allShapes: [Shape] { layers.flatMap(\.shapes) }

    // MARK: Geometry

    /// The picture rotated and flipped, before cropping: the space shapes live in.
    public var canvasSize: CGSize {
        quarterTurns % 2 == 0 ? imageSize : CGSize(width: imageSize.height, height: imageSize.width)
    }

    public var canvasRect: CGRect { CGRect(origin: .zero, size: canvasSize) }

    /// The part of the canvas that is kept.
    public var cropRect: CGRect { crop ?? canvasRect }

    /// The size of the result before any resizing.
    public var naturalSize: CGSize {
        CGSize(width: max(1, cropRect.width.rounded()), height: max(1, cropRect.height.rounded()))
    }

    /// The size of the saved picture.
    public var finalSize: CGSize { outputSize ?? naturalSize }

    /// Original picture pixels to canvas pixels.
    public var orientation: CGAffineTransform {
        Self.orientation(of: imageSize, turns: quarterTurns, flipped: flipped)
    }

    static func orientation(of size: CGSize, turns: Int, flipped: Bool) -> CGAffineTransform {
        var transform = CGAffineTransform.identity
        var current = size
        if flipped { transform = transform.concatenating(flip(in: current)) }
        for _ in 0..<((turns % 4 + 4) % 4) {
            transform = transform.concatenating(turnClockwise(in: current))
            current = CGSize(width: current.height, height: current.width)
        }
        return transform
    }

    /// Mirrors left to right a space of `size`.
    static func flip(in size: CGSize) -> CGAffineTransform {
        CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: size.width, ty: 0)
    }

    /// Turns a space of `size` a quarter clockwise (y pointing down): (x, y) goes to (height - y, x).
    static func turnClockwise(in size: CGSize) -> CGAffineTransform {
        CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: size.height, ty: 0)
    }

    /// Canvas pixels to the result's pixels, before resizing.
    public var cropTransform: CGAffineTransform {
        CGAffineTransform(translationX: -cropRect.minX, y: -cropRect.minY)
    }

    /// Turns the picture a quarter, shapes and crop with it; text and pictures stay upright.
    public mutating func rotate(clockwise: Bool) {
        let size = canvasSize
        let step = clockwise ? Self.turnClockwise(in: size)
                             : Self.turnClockwise(in: CGSize(width: size.height, height: size.width)).inverted()
        quarterTurns = ((quarterTurns + (clockwise ? 1 : 3)) % 4 + 4) % 4
        transformContent(by: step)
        if let size = outputSize { outputSize = CGSize(width: size.height, height: size.width) }
    }

    /// Mirrors the picture, left to right or top to bottom.
    public mutating func flip(horizontally: Bool = true) {
        let size = canvasSize
        // Mirroring the canvas reverses the turns and mirrors the original: H·R^k = R^-k·F.
        quarterTurns = (4 - quarterTurns) % 4
        flipped.toggle()
        var step = Self.flip(in: size)
        if !horizontally {
            // Top to bottom is left to right then half a turn.
            quarterTurns = (quarterTurns + 2) % 4
            step = step.concatenating(CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: size.width, ty: size.height))
        }
        transformContent(by: step)
    }

    private mutating func transformContent(by step: CGAffineTransform) {
        for l in layers.indices {
            for s in layers[l].shapes.indices { layers[l].shapes[s] = layers[l].shapes[s].applying(step) }
        }
        if let crop { self.crop = crop.applying(step).standardized }
    }

    /// Crops to `rect` (canvas space), kept inside the picture; nil or the whole picture removes the crop.
    public mutating func setCrop(_ rect: CGRect?) {
        guard let rect else { crop = nil; return }
        let kept = rect.standardized.intersection(canvasRect)
        guard !kept.isNull else { crop = nil; return }
        // Whole pixels, rounded rather than grown, so 2400.0000001 stays 2400.
        let minX = kept.minX.rounded(), minY = kept.minY.rounded()
        let rounded = CGRect(x: minX, y: minY, width: kept.maxX.rounded() - minX, height: kept.maxY.rounded() - minY)
        if rounded.width < 1 || rounded.height < 1 || rounded == canvasRect { crop = nil; return }
        crop = rounded
    }

    // MARK: Layers

    public func layerIndex(_ id: UUID) -> Int? { layers.firstIndex { $0.id == id } }

    /// The layer and position of a shape.
    public func locate(_ shapeID: UUID) -> (layer: Int, shape: Int)? {
        for (l, layer) in layers.enumerated() {
            if let s = layer.shapes.firstIndex(where: { $0.id == shapeID }) { return (l, s) }
        }
        return nil
    }

    public func shape(_ id: UUID) -> Shape? {
        locate(id).map { layers[$0.layer].shapes[$0.shape] }
    }

    /// A new empty layer just above `above` (or on top), named after the next free number.
    @discardableResult
    public mutating func addLayer(above: UUID? = nil) -> UUID {
        var number = layers.count + 1
        while layers.contains(where: { $0.name == "Layer \(number)" }) { number += 1 }
        let layer = Layer(name: "Layer \(number)")
        let index = above.flatMap(layerIndex).map { $0 + 1 } ?? layers.count
        layers.insert(layer, at: index)
        return layer.id
    }

    /// Removes a layer and its shapes; the last layer is emptied instead, so there always is one.
    public mutating func removeLayer(_ id: UUID) {
        guard let index = layerIndex(id) else { return }
        if layers.count == 1 { layers[0].shapes = [] } else { layers.remove(at: index) }
    }

    /// Moves a layer up (towards the top) or down the stack by `offset` places.
    public mutating func moveLayer(_ id: UUID, by offset: Int) {
        guard let index = layerIndex(id) else { return }
        let target = min(max(index + offset, 0), layers.count - 1)
        guard target != index else { return }
        layers.insert(layers.remove(at: index), at: target)
    }

    /// Merges a layer into the one under it. The shapes stay editable: the upper layer's opacity is
    /// carried into each of its shapes, and the merged layer keeps the lower layer's name and blending.
    @discardableResult
    public mutating func mergeDown(_ id: UUID) -> UUID? {
        guard let index = layerIndex(id), index > 0 else { return nil }
        let upper = layers.remove(at: index)
        let carried = upper.isVisible ? upper.shapes.map { shape -> Shape in
            var shape = shape
            shape.style.opacity *= upper.opacity
            return shape
        } : []
        layers[index - 1].shapes += carried
        return layers[index - 1].id
    }

    /// Adds a shape on top of a layer (the top layer if `layer` is missing).
    public mutating func add(_ shape: Shape, to layer: UUID?) {
        var shape = shape
        if shape.kind == .step && shape.number == nil { shape.number = nextStepNumber }
        let index = layer.flatMap(layerIndex) ?? layers.count - 1
        layers[index].shapes.append(shape)
    }

    public mutating func update(_ shape: Shape) {
        guard let (l, s) = locate(shape.id) else { return }
        layers[l].shapes[s] = shape
    }

    public mutating func remove(_ ids: Set<UUID>) {
        let hadSteps = allShapes.contains { ids.contains($0.id) && $0.kind == .step }
        for l in layers.indices { layers[l].shapes.removeAll { ids.contains($0.id) } }
        if hadSteps { renumberSteps() }
    }

    /// Moves a shape within its layer: to the top, up one, down one or to the bottom.
    public enum Order { case front, forward, backward, back }

    public mutating func arrange(_ id: UUID, _ order: Order) {
        guard let (l, s) = locate(id) else { return }
        var shapes = layers[l].shapes
        let shape = shapes.remove(at: s)
        let target: Int = switch order {
        case .front: shapes.count
        case .forward: min(s + 1, shapes.count)
        case .backward: max(s - 1, 0)
        case .back: 0
        }
        shapes.insert(shape, at: target)
        layers[l].shapes = shapes
    }

    /// Moves a shape to the top of another layer.
    public mutating func move(_ id: UUID, toLayer layer: UUID) {
        guard let (l, s) = locate(id), let target = layerIndex(layer), target != l else { return }
        let shape = layers[l].shapes.remove(at: s)
        layers[target].shapes.append(shape)
    }

    /// Step markers count 1, 2, 3 in the order they were placed.
    public var nextStepNumber: Int { (allShapes.compactMap(\.number).max() ?? 0) + 1 }

    /// After a step is removed, the others close the gap.
    public mutating func renumberSteps() {
        var next = 1
        for l in layers.indices {
            for s in layers[l].shapes.indices where layers[l].shapes[s].kind == .step {
                layers[l].shapes[s].number = next
                next += 1
            }
        }
    }

    /// The topmost visible shape at `point` (canvas space).
    public func hitTest(_ point: CGPoint, tolerance: Double) -> Shape? {
        for layer in layers.reversed() where layer.isVisible {
            if let shape = layer.shapes.reversed().first(where: { $0.contains(point, tolerance: tolerance) }) {
                return shape
            }
        }
        return nil
    }

    /// Visible shapes touching `rect`, for a rubber-band selection.
    public func shapes(in rect: CGRect) -> [Shape] {
        layers.filter(\.isVisible).flatMap(\.shapes).filter { $0.bounds.intersects(rect) }
    }
}
