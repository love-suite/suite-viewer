import CoreGraphics
import CoreImage
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Draws an editable version over its picture: the same code shows it in the editor and flattens it
/// into the saved picture, so what is seen is what is saved.
public final class EditRenderer {
    /// The original picture, upright (its EXIF orientation applied).
    public let original: CGImage
    /// Pictures placed on top (inserted pictures, signatures), by asset name.
    public var assets: [String: CGImage] = [:]

    private let ciContext = CIContext(options: [.cacheIntermediates: false])
    private var adjustedCache: (Adjustments, CGImage)?
    private var masksCache: (Adjustments, blurred: CGImage, pixelated: CGImage)?

    public init(original: CGImage) {
        self.original = original
    }

    public var imageSize: CGSize { CGSize(width: original.width, height: original.height) }

    // MARK: Light and colour

    /// The original with its light and colour adjusted, computed again only when they change.
    public func adjustedImage(_ adjustments: Adjustments) -> CGImage {
        if adjustments.isIdentity { return original }
        if let (cached, image) = adjustedCache, cached == adjustments { return image }
        let input = CIImage(cgImage: original)
        let output = Self.apply(adjustments, to: input).cropped(to: input.extent)
        let image = ciContext.createCGImage(output, from: input.extent, format: .RGBA8,
                                            colorSpace: Self.workingSpace(for: original)) ?? original
        adjustedCache = (adjustments, image)
        return image
    }

    static func workingSpace(for image: CGImage) -> CGColorSpace {
        if let space = image.colorSpace, space.model == .rgb, space.supportsOutput { return space }
        return CGColorSpace(name: CGColorSpace.sRGB)!
    }

    static func apply(_ a: Adjustments, to input: CIImage) -> CIImage {
        var image = input
        func filter(_ name: String, _ values: [String: Any]) {
            guard let f = CIFilter(name: name) else { return }
            f.setValue(image, forKey: kCIInputImageKey)
            for (key, value) in values { f.setValue(value, forKey: key) }
            if let output = f.outputImage { image = output }
        }
        if a.autoEnhance {
            for f in image.autoAdjustmentFilters(options: [.redEye: false]) {
                f.setValue(image, forKey: kCIInputImageKey)
                if let output = f.outputImage { image = output }
            }
        }
        if a.exposure != 0 { filter("CIExposureAdjust", [kCIInputEVKey: a.exposure * 2]) }
        if a.highlights != 0 || a.shadows != 0 {
            let s = 0.12 * a.shadows, h = 0.12 * a.highlights
            filter("CIToneCurve", [
                "inputPoint0": CIVector(x: 0, y: max(0, s * 0.4)),
                "inputPoint1": CIVector(x: 0.25, y: 0.25 + s),
                "inputPoint2": CIVector(x: 0.5, y: 0.5 + (s + h) / 4),
                "inputPoint3": CIVector(x: 0.75, y: 0.75 + h),
                "inputPoint4": CIVector(x: 1, y: min(1, 1 + h * 0.4)),
            ])
        }
        if a.brightness != 0 || a.contrast != 0 || a.saturation != 0 {
            filter("CIColorControls", [kCIInputBrightnessKey: a.brightness * 0.25,
                                       kCIInputContrastKey: 1 + a.contrast * 0.5,
                                       kCIInputSaturationKey: 1 + a.saturation])
        }
        if a.warmth != 0 || a.tint != 0 {
            // Telling the filter the picture was lit by a colder light warms it.
            filter("CITemperatureAndTint", ["inputNeutral": CIVector(x: 6500 + a.warmth * 3000, y: a.tint * 60),
                                            "inputTargetNeutral": CIVector(x: 6500, y: 0)])
        }
        if a.sharpness > 0 { filter("CISharpenLuminance", [kCIInputSharpnessKey: a.sharpness * 1.5]) }
        if a.vignette > 0 {
            let radius = max(input.extent.width, input.extent.height) / 2
            filter("CIVignetteEffect", [kCIInputCenterKey: CIVector(x: input.extent.midX, y: input.extent.midY),
                                        kCIInputRadiusKey: radius * 1.1, kCIInputIntensityKey: a.vignette,
                                        "inputFalloff": 0.6])
        }
        switch a.filter {
        case .none: break
        case .vivid: filter("CIVibrance", ["inputAmount": 0.7])
        case .mono: filter("CIPhotoEffectMono", [:])
        case .noir: filter("CIPhotoEffectNoir", [:])
        case .tonal: filter("CIPhotoEffectTonal", [:])
        case .chrome: filter("CIPhotoEffectChrome", [:])
        case .fade: filter("CIPhotoEffectFade", [:])
        case .instant: filter("CIPhotoEffectInstant", [:])
        case .process: filter("CIPhotoEffectProcess", [:])
        case .transfer: filter("CIPhotoEffectTransfer", [:])
        }
        return image
    }

    /// The adjusted picture blurred and pixelated, what blur and pixelate shapes show.
    public func maskImages(_ adjustments: Adjustments) -> (blurred: CGImage, pixelated: CGImage) {
        if let cache = masksCache, cache.0 == adjustments { return (cache.blurred, cache.pixelated) }
        let input = CIImage(cgImage: adjustedImage(adjustments))
        let side = max(input.extent.width, input.extent.height)
        let blurred = input.clampedToExtent()
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: max(6, side / 70)])
            .cropped(to: input.extent)
        let pixelated = input.clampedToExtent()
            .applyingFilter("CIPixellate", parameters: [kCIInputScaleKey: max(8, side / 45),
                                                        kCIInputCenterKey: CIVector(x: 0, y: 0)])
            .cropped(to: input.extent)
        let space = Self.workingSpace(for: original)
        let result = (ciContext.createCGImage(blurred, from: input.extent, format: .RGBA8, colorSpace: space) ?? original,
                      ciContext.createCGImage(pixelated, from: input.extent, format: .RGBA8, colorSpace: space) ?? original)
        masksCache = (adjustments, result.0, result.1)
        return result
    }

    private var previewCache: (Adjustments, Int, CGImage)?

    /// The adjusted picture at most `maxSide` pixels wide or high, for drawing on screen.
    public func previewImage(_ adjustments: Adjustments, maxSide: Int) -> CGImage {
        let full = adjustedImage(adjustments)
        guard max(full.width, full.height) > maxSide else { return full }
        if let (cached, side, image) = previewCache, cached == adjustments, side == maxSide { return image }
        let scale = Double(maxSide) / Double(max(full.width, full.height))
        let width = max(1, Int(Double(full.width) * scale)), height = max(1, Int(Double(full.height) * scale))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: Self.workingSpace(for: original),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return full }
        context.interpolationQuality = .high
        context.draw(full, in: CGRect(x: 0, y: 0, width: width, height: height))
        let image = context.makeImage() ?? full
        previewCache = (adjustments, maxSide, image)
        return image
    }

    // MARK: Drawing

    /// Draws the picture and its shapes into `context`, whose transform maps canvas pixels (origin at
    /// the top left, y down) to the device. Shapes in `hidden` are left out (one being typed into).
    /// `base`, a smaller copy of the adjusted picture, draws faster on screen when zoomed out.
    public func drawCanvas(_ document: EditDocument, in context: CGContext, hidden: Set<UUID> = [],
                           base: CGImage? = nil) {
        context.saveGState()
        context.concatenate(document.orientation)
        Self.draw(base ?? adjustedImage(document.adjustments), in: CGRect(origin: .zero, size: document.imageSize), context)
        context.restoreGState()
        drawLayers(document, in: context, hidden: hidden)
    }

    /// Only the shapes, in canvas space.
    public func drawLayers(_ document: EditDocument, in context: CGContext, hidden: Set<UUID> = []) {
        lazy var masks = maskImages(document.adjustments)
        for layer in document.layers where layer.isVisible && !layer.shapes.isEmpty {
            let grouped = layer.opacity < 1 || layer.blend != .normal
            context.saveGState()
            if grouped {
                context.setAlpha(layer.opacity)
                context.setBlendMode(layer.blend.cgBlendMode)
                context.beginTransparencyLayer(auxiliaryInfo: nil)
            }
            for shape in layer.shapes where !hidden.contains(shape.id) {
                let needsMasks = shape.kind == .blur || shape.kind == .pixelate
                draw(shape, in: context, document: document,
                     mask: needsMasks ? (shape.kind == .blur ? masks.blurred : masks.pixelated) : nil)
            }
            if grouped { context.endTransparencyLayer() }
            context.restoreGState()
        }
    }

    /// The flattened picture: what Save writes.
    public func render(_ document: EditDocument) -> CGImage? {
        let size = document.finalSize, natural = document.naturalSize
        let width = Int(size.width.rounded()), height = Int(size.height.rounded())
        guard width > 0, height > 0,
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: Self.workingSpace(for: original),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.interpolationQuality = .high
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        context.scaleBy(x: CGFloat(width) / natural.width, y: CGFloat(height) / natural.height)
        context.concatenate(document.cropTransform)
        context.clip(to: document.cropRect)
        drawCanvas(document, in: context)
        return context.makeImage()
    }

    /// Draws an image right side up into a rectangle of a y-down context.
    public static func draw(_ image: CGImage, in rect: CGRect, _ context: CGContext) {
        context.saveGState()
        context.translateBy(x: rect.minX, y: rect.maxY)
        context.scaleBy(x: 1, y: -1)
        context.draw(image, in: CGRect(origin: .zero, size: rect.size))
        context.restoreGState()
    }

    func draw(_ shape: Shape, in context: CGContext, document: EditDocument, mask: CGImage?) {
        let style = shape.style
        context.saveGState()
        defer { context.restoreGState() }
        let translucent = style.opacity < 1
        if translucent {
            context.setAlpha(style.opacity)
            context.beginTransparencyLayer(auxiliaryInfo: nil)
        }
        defer { if translucent { context.endTransparencyLayer() } }
        if style.shadow {
            context.setShadow(offset: CGSize(width: 0, height: -max(1, style.lineWidth / 3)),
                              blur: max(2, style.lineWidth * 1.5), color: CGColor(gray: 0, alpha: 0.5))
        }
        context.setLineJoin(.round)
        context.setLineCap(.round)
        context.setLineWidth(style.lineWidth)
        context.setStrokeColor(style.stroke.cgColor)
        if style.dashed { context.setLineDash(phase: 0, lengths: [style.lineWidth * 2.5, style.lineWidth * 2]) }
        let frame = shape.frame
        switch shape.kind {
        case .rectangle, .ellipse:
            let path = shape.kind == .rectangle
                ? CGPath(roundedRect: frame, cornerWidth: min(style.cornerRadius, frame.width / 2),
                         cornerHeight: min(style.cornerRadius, frame.height / 2), transform: nil)
                : CGPath(ellipseIn: frame, transform: nil)
            if let fill = style.fill {
                context.setFillColor(fill.cgColor)
                context.addPath(path)
                context.fillPath()
            }
            if style.lineWidth > 0 {
                context.addPath(path)
                context.strokePath()
            }
        case .line:
            guard shape.points.count == 2 else { return }
            context.strokeLineSegments(between: shape.points)
        case .arrow:
            guard shape.points.count == 2 else { return }
            drawArrow(from: shape.points[0], to: shape.points[1], style: style, in: context)
        case .pen, .highlighter:
            if shape.kind == .highlighter {
                context.setBlendMode(.multiply)
                context.setLineCap(.butt)
            }
            if shape.points.count == 1 {
                let p = shape.points[0], r = style.lineWidth / 2
                context.setFillColor(style.stroke.cgColor)
                context.fillEllipse(in: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2))
            } else {
                context.addPath(Self.smoothPath(shape.points))
                context.strokePath()
            }
        case .text:
            if let fill = style.fill {
                context.setFillColor(fill.cgColor)
                let radius = style.fontSize * 0.2
                context.addPath(CGPath(roundedRect: frame, cornerWidth: radius, cornerHeight: radius, transform: nil))
                context.fillPath()
                context.setShadow(offset: .zero, blur: 0, color: nil)
            }
            TextLayout.draw(shape.text, style: style, in: frame.insetBy(dx: TextLayout.padding(style),
                                                                         dy: TextLayout.padding(style)), context)
        case .step:
            let side = max(frame.width, frame.height)
            let circle = CGRect(x: frame.midX - side / 2, y: frame.midY - side / 2, width: side, height: side)
            context.setFillColor(style.stroke.cgColor)
            context.fillEllipse(in: circle)
            context.setShadow(offset: .zero, blur: 0, color: nil)
            var label = style
            label.stroke = style.stroke.isLight ? .black : .white
            label.fontSize = side * 0.55
            label.fill = nil
            let text = "\(shape.number ?? 1)"
            let size = TextLayout.size(text, style: label, width: .greatestFiniteMagnitude)
            TextLayout.draw(text, style: label, in: CGRect(x: circle.midX - size.width / 2, y: circle.midY - size.height / 2,
                                                           width: size.width + 1, height: size.height), context)
        case .blur, .pixelate:
            guard let mask else { return }
            context.clip(to: frame)
            context.concatenate(document.orientation)
            Self.draw(mask, in: CGRect(origin: .zero, size: document.imageSize), context)
        case .redact:
            context.setFillColor(style.stroke.cgColor)
            context.fill(frame)
        case .picture:
            if let name = shape.asset, let image = assets[name] {
                Self.draw(image, in: frame, context)
            } else {
                context.setFillColor(CGColor(gray: 0.5, alpha: 0.4))
                context.fill(frame)
            }
        }
    }

    private func drawArrow(from start: CGPoint, to end: CGPoint, style: ShapeStyle, in context: CGContext) {
        let length = hypot(end.x - start.x, end.y - start.y)
        guard length > 0 else { return }
        let head = min(max(style.lineWidth * 3.5, 10), length * (style.doubleHeaded ? 0.45 : 0.8))
        let ux = (end.x - start.x) / length, uy = (end.y - start.y) / length
        func headPath(at tip: CGPoint, ux: Double, uy: Double) -> CGPath {
            let base = CGPoint(x: tip.x - ux * head, y: tip.y - uy * head)
            let half = head * 0.45
            let path = CGMutablePath()
            path.move(to: tip)
            path.addLine(to: CGPoint(x: base.x - uy * half, y: base.y + ux * half))
            path.addLine(to: CGPoint(x: base.x + uy * half, y: base.y - ux * half))
            path.closeSubpath()
            return path
        }
        let shaftEnd = CGPoint(x: end.x - ux * head * 0.7, y: end.y - uy * head * 0.7)
        let shaftStart = style.doubleHeaded ? CGPoint(x: start.x + ux * head * 0.7, y: start.y + uy * head * 0.7) : start
        context.strokeLineSegments(between: [shaftStart, shaftEnd])
        context.setLineDash(phase: 0, lengths: [])
        context.setFillColor(style.stroke.cgColor)
        context.addPath(headPath(at: end, ux: ux, uy: uy))
        if style.doubleHeaded { context.addPath(headPath(at: start, ux: -ux, uy: -uy)) }
        context.fillPath()
    }

    /// A smooth curve through pen points: quadratic curves between their midpoints.
    static func smoothPath(_ points: [CGPoint]) -> CGPath {
        let path = CGMutablePath()
        guard let first = points.first else { return path }
        path.move(to: first)
        if points.count == 2 {
            path.addLine(to: points[1])
            return path
        }
        for i in 1..<points.count {
            let previous = points[i - 1], point = points[i]
            path.addQuadCurve(to: CGPoint(x: (previous.x + point.x) / 2, y: (previous.y + point.y) / 2), control: previous)
        }
        path.addLine(to: points[points.count - 1])
        return path
    }
}

extension RGBA {
    /// Light colours take dark text.
    public var isLight: Bool { 0.299 * red + 0.587 * green + 0.114 * blue > 0.6 }
}

/// Lays out and draws the text of text shapes with Core Text.
public enum TextLayout {
    /// Room around the text when it has a background.
    public static func padding(_ style: ShapeStyle) -> Double { style.fill == nil ? 0 : style.fontSize * 0.3 }

    static func font(_ style: ShapeStyle) -> CTFont {
        if let name = style.fontName { return CTFontCreateWithName(name as CFString, style.fontSize, nil) }
        return CTFontCreateUIFontForLanguage(.emphasizedSystem, style.fontSize, nil)
            ?? CTFontCreateWithName("Helvetica-Bold" as CFString, style.fontSize, nil)
    }

    static func attributed(_ text: String, _ style: ShapeStyle) -> NSAttributedString {
        NSAttributedString(string: text.isEmpty ? " " : text, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font(style),
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): style.stroke.cgColor,
        ])
    }

    /// The size the text takes when wrapped to `width`.
    public static func size(_ text: String, style: ShapeStyle, width: Double) -> CGSize {
        let setter = CTFramesetterCreateWithAttributedString(attributed(text, style))
        let size = CTFramesetterSuggestFrameSizeWithConstraints(setter, CFRange(), nil,
                                                                CGSize(width: width, height: .greatestFiniteMagnitude), nil)
        return CGSize(width: ceil(size.width), height: ceil(size.height))
    }

    /// The frame a text shape needs at `width` (its padding included).
    public static func frameSize(_ text: String, style: ShapeStyle, width: Double) -> CGSize {
        let pad = padding(style)
        let inner = size(text, style: style, width: max(1, width - 2 * pad))
        return CGSize(width: width, height: inner.height + 2 * pad)
    }

    /// Draws text from the top of `rect` in a y-down context.
    public static func draw(_ text: String, style: ShapeStyle, in rect: CGRect, _ context: CGContext) {
        let setter = CTFramesetterCreateWithAttributedString(attributed(text, style))
        let height = max(rect.height, size(text, style: style, width: rect.width).height)
        context.saveGState()
        context.textMatrix = .identity
        context.translateBy(x: rect.minX, y: rect.minY + height)
        context.scaleBy(x: 1, y: -1)
        let frame = CTFramesetterCreateFrame(setter, CFRange(), CGPath(rect: CGRect(x: 0, y: 0, width: rect.width, height: height),
                                                                       transform: nil), nil)
        CTFrameDraw(frame, context)
        context.restoreGState()
    }
}

/// Reading and writing picture files.
public enum PictureFile {
    /// The picture at full size, upright (its EXIF orientation applied).
    public static func loadUpright(_ url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return upright(source)
    }

    public static func loadUpright(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return upright(source)
    }

    private static func upright(_ source: CGImageSource) -> CGImage? {
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
        let width = properties[kCGImagePropertyPixelWidth] as? Int ?? 0
        let height = properties[kCGImagePropertyPixelHeight] as? Int ?? 0
        let orientation = properties[kCGImagePropertyOrientation] as? UInt32 ?? 1
        if orientation == 1 || width == 0 { return CGImageSourceCreateImageAtIndex(source, 0, nil) }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(width, height),
            kCGImageSourceShouldCacheImmediately: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
            ?? CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    /// The file's type, if pictures of that type can be written back.
    public static func writableType(of url: URL) -> UTType? {
        guard let type = UTType(filenameExtension: url.pathExtension) else { return nil }
        let writable = (CGImageDestinationCopyTypeIdentifiers() as? [String]) ?? []
        guard writable.contains(type.identifier) else { return nil }
        // An animated picture would lose its animation.
        if let source = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(source) > 1 { return nil }
        return type
    }

    /// The picture encoded as `type`, with the metadata of `source` (camera, date, place) but upright.
    public static func encode(_ image: CGImage, as type: UTType, metadataFrom source: URL? = nil,
                              quality: Double = 0.92) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil) else { return nil }
        var properties: [CFString: Any] = [:]
        if let source, let input = CGImageSourceCreateWithURL(source as CFURL, nil),
           let metadata = CGImageSourceCopyPropertiesAtIndex(input, 0, nil) as? [CFString: Any] {
            for key in [kCGImagePropertyExifDictionary, kCGImagePropertyGPSDictionary, kCGImagePropertyIPTCDictionary,
                        kCGImagePropertyTIFFDictionary] {
                if let value = metadata[key] { properties[key] = value }
            }
            if var tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
                tiff[kCGImagePropertyTIFFOrientation] = 1
                properties[kCGImagePropertyTIFFDictionary] = tiff
            }
            if var exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any] {
                exif[kCGImagePropertyExifPixelXDimension] = image.width
                exif[kCGImagePropertyExifPixelYDimension] = image.height
                properties[kCGImagePropertyExifDictionary] = exif
            }
        }
        properties[kCGImagePropertyOrientation] = 1
        properties[kCGImageDestinationLossyCompressionQuality] = quality
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    /// Writes into the existing file rather than replacing it, so it keeps its identity (and its
    /// place in the edits store), its Finder tags and its creation date.
    public static func write(_ data: Data, to url: URL) throws {
        if FileManager.default.fileExists(atPath: url.path) {
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.truncate(atOffset: 0)
            try handle.write(contentsOf: data)
        } else {
            try data.write(to: url)
        }
    }
}
