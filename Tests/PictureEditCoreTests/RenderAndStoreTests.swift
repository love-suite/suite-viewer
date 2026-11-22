import CoreGraphics
import CoreText
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import PictureEditCore

/// A picture of one colour, or with a dark square in its top left quarter.
func makePicture(width: Int = 200, height: Int = 100, gray: CGFloat = 1, square: Bool = false,
                 text: String? = nil) -> CGImage {
    let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setFillColor(CGColor(gray: gray, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    if square {
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        // Core Graphics' origin is at the bottom left: this is the top left quarter.
        context.fill(CGRect(x: 0, y: height / 2, width: width / 2, height: height / 2))
    }
    if let text {
        var style = ShapeStyle()
        style.stroke = .black
        style.fontSize = Double(height) / 4
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        TextLayout.draw(text, style: style, in: CGRect(x: 20, y: Double(height) / 3, width: Double(width) - 40,
                                                       height: Double(height) / 2), context)
    }
    return context.makeImage()!
}

/// The colour at (x, y), origin at the top left, as 0–255 components.
func pixel(_ image: CGImage, _ x: Int, _ y: Int) -> (r: Int, g: Int, b: Int) {
    var data = [UInt8](repeating: 0, count: 4)
    let context = CGContext(data: &data, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.draw(image, in: CGRect(x: -x, y: y - image.height + 1, width: image.width, height: image.height))
    return (Int(data[0]), Int(data[1]), Int(data[2]))
}

@Suite struct RendererTests {
    @Test func drawsShapesWhereTheyAre() throws {
        let renderer = EditRenderer(original: makePicture())
        var doc = EditDocument(imageSize: renderer.imageSize)
        var style = ShapeStyle()
        style.stroke = .red
        doc.add(Shape(kind: .redact, points: [CGPoint(x: 150, y: 10), CGPoint(x: 190, y: 40)], style: style), to: nil)
        let image = try #require(renderer.render(doc))
        #expect(image.width == 200 && image.height == 100)
        let inside = pixel(image, 170, 20)
        #expect(inside.r > 200 && inside.g < 100)
        let outside = pixel(image, 50, 80)
        #expect(outside.r > 240 && outside.g > 240)
    }

    @Test func cropsTurnsAndResizes() throws {
        let renderer = EditRenderer(original: makePicture(square: true))
        var doc = EditDocument(imageSize: renderer.imageSize)
        doc.rotate(clockwise: true)
        // Turned clockwise, the dark top left quarter is now the top right quarter of a 100 x 200 canvas.
        let turned = try #require(renderer.render(doc))
        #expect(turned.width == 100 && turned.height == 200)
        #expect(pixel(turned, 75, 50).r < 30)
        #expect(pixel(turned, 25, 50).r > 220)
        doc.setCrop(CGRect(x: 50, y: 0, width: 50, height: 100))
        doc.outputSize = CGSize(width: 25, height: 50)
        let cropped = try #require(renderer.render(doc))
        #expect(cropped.width == 25 && cropped.height == 50)
        #expect(pixel(cropped, 12, 25).r < 30)
    }

    @Test func layersBlendAndHide() throws {
        let renderer = EditRenderer(original: makePicture())
        var doc = EditDocument(imageSize: renderer.imageSize)
        var style = ShapeStyle()
        style.stroke = .black
        doc.add(Shape(kind: .redact, points: [.zero, CGPoint(x: 100, y: 100)], style: style), to: nil)
        doc.layers[0].opacity = 0.5
        let half = try #require(renderer.render(doc))
        #expect((100...160).contains(pixel(half, 50, 50).r))
        doc.layers[0].isVisible = false
        #expect(pixel(try #require(renderer.render(doc)), 50, 50).r > 240)
    }

    @Test func warmthWarmsAndExposureBrightens() throws {
        let renderer = EditRenderer(original: makePicture(gray: 0.5))
        var adjustments = Adjustments()
        adjustments.warmth = 1
        let warm = pixel(renderer.adjustedImage(adjustments), 10, 10)
        #expect(warm.r > warm.b + 10)
        adjustments = Adjustments()
        adjustments.exposure = 0.5
        let bright = pixel(renderer.adjustedImage(adjustments), 10, 10)
        #expect(bright.r > pixel(renderer.original, 10, 10).r + 20)
        adjustments = Adjustments()
        adjustments.filter = .mono
        adjustments.warmth = 1
        let mono = pixel(renderer.adjustedImage(adjustments), 10, 10)
        #expect(abs(mono.r - mono.b) < 4)
    }

    @Test func blurHidesWhatIsUnder() throws {
        let renderer = EditRenderer(original: makePicture(width: 400, height: 200, square: true))
        var doc = EditDocument(imageSize: renderer.imageSize)
        // Across the edge of the dark square, which the blur smudges.
        doc.add(Shape(kind: .blur, points: [CGPoint(x: 150, y: 20), CGPoint(x: 250, y: 80)], style: ShapeStyle()), to: nil)
        let image = try #require(renderer.render(doc))
        let edge = pixel(image, 196, 50).r
        #expect(edge > 20 && edge < 235)
        #expect(pixel(image, 50, 50).r < 10)
    }

    @Test func textAndStepsDraw() throws {
        let renderer = EditRenderer(original: makePicture())
        var doc = EditDocument(imageSize: renderer.imageSize)
        var style = ShapeStyle()
        style.stroke = .blue
        style.fontSize = 30
        doc.add(Shape(kind: .text, points: [CGPoint(x: 10, y: 10), CGPoint(x: 190, y: 50)], style: style, text: "███"), to: nil)
        doc.add(Shape(kind: .step, points: [CGPoint(x: 150, y: 60), CGPoint(x: 190, y: 100)], style: style), to: nil)
        let image = try #require(renderer.render(doc))
        var blue = 0
        for x in stride(from: 10, to: 120, by: 2) where pixel(image, x, 30).b > 200 && pixel(image, x, 30).r < 80 { blue += 1 }
        #expect(blue > 5)
        #expect(pixel(image, 155, 80).b > 200)
        let size = TextLayout.frameSize("Hello\nWorld", style: style, width: 300)
        #expect(size.height > style.fontSize * 2)
    }

    @Test func picturesShowTheirAsset() throws {
        let renderer = EditRenderer(original: makePicture())
        renderer.assets["dark"] = makePicture(width: 10, height: 10, gray: 0)
        var doc = EditDocument(imageSize: renderer.imageSize)
        doc.add(Shape(kind: .picture, points: [CGPoint(x: 0, y: 0), CGPoint(x: 40, y: 40)], style: ShapeStyle(),
                      asset: "dark"), to: nil)
        let image = try #require(renderer.render(doc))
        #expect(pixel(image, 20, 20).r < 10)
    }
}

@Suite struct PictureFileTests {
    let folder: URL = {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("PictureFileTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    @Test func writesInPlaceKeepingTheFile() throws {
        let url = folder.appendingPathComponent("a.png")
        try #require(PictureFile.encode(makePicture(), as: .png)).write(to: url)
        let before = FileFingerprint.identity(of: url)
        let data = try #require(PictureFile.encode(makePicture(width: 20, height: 10, gray: 0), as: .png, metadataFrom: url))
        try PictureFile.write(data, to: url)
        #expect(FileFingerprint.identity(of: url).fileNumber == before.fileNumber)
        let read = try #require(PictureFile.loadUpright(url))
        #expect(read.width == 20 && pixel(read, 5, 5).r < 10)
        #expect(PictureFile.writableType(of: url) == .png)
    }

    @Test func appliesTheOrientation() throws {
        let url = folder.appendingPathComponent("turned.jpg")
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
        // Orientation 6: the picture is shown turned clockwise.
        CGImageDestinationAddImage(destination, makePicture(width: 60, height: 30),
                                   [kCGImagePropertyOrientation: 6] as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))
        let image = try #require(PictureFile.loadUpright(url))
        #expect(image.width == 30 && image.height == 60)
    }
}

@Suite struct EditStoreTests {
    let root: URL
    let store: EditStore
    let picture: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("EditStoreTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        store = EditStore(folder: root.appendingPathComponent("Edits"))
        picture = root.appendingPathComponent("photo.png")
        try PictureFile.encode(makePicture(), as: .png)!.write(to: picture)
    }

    private func edits() -> StoredEdits {
        var doc = EditDocument(imageSize: CGSize(width: 200, height: 100))
        var history = EditHistory(doc)
        doc.add(Shape(kind: .picture, points: [.zero, CGPoint(x: 10, y: 10)], style: ShapeStyle(), asset: "sig"), to: nil)
        history.record(doc, name: "Picture")
        return StoredEdits(history: history, assets: ["sig": Data([1, 2, 3])])
    }

    @Test func keepsTheOriginalAndTheEditsApart() throws {
        #expect(store.record(for: picture) == nil)
        let record = try store.create(for: picture)
        let saved = edits()
        try store.save(saved, for: record)
        #expect(try Data(contentsOf: store.originalURL(record)) == Data(contentsOf: picture))
        let found = try #require(store.record(for: picture))
        #expect(found.id == record.id)
        #expect(try store.load(found) == saved)
        // Nothing was added next to the picture.
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).sorted() == ["Edits", "photo.png"])
        let json = try String(contentsOf: root.appendingPathComponent("Edits/\(record.id)/edits.json"), encoding: .utf8)
        #expect(json.contains(EditStore.format))
    }

    @Test func followsARenamedFile() throws {
        let record = try store.create(for: picture)
        try store.save(edits(), for: record)
        let renamed = root.appendingPathComponent("renamed.png")
        try FileManager.default.moveItem(at: picture, to: renamed)
        let found = try #require(store.record(for: renamed))
        #expect(found.id == record.id)
        #expect(found.path == renamed.standardizedFileURL.path)
    }

    @Test func forgetsAFileChangedElsewhere() throws {
        let record = try store.create(for: picture)
        try store.save(edits(), for: record)
        try PictureFile.encode(makePicture(gray: 0), as: .png)!.write(to: picture)
        #expect(store.record(for: picture) == nil)
        // Starting again replaces the stale record.
        _ = try store.create(for: picture)
        #expect(store.records().count == 1)
    }

    @Test func recognisesTheSavedPicture() throws {
        let record = try store.create(for: picture)
        try store.save(edits(), for: record)
        try PictureFile.write(PictureFile.encode(makePicture(gray: 0.3), as: .png)!, to: picture)
        #expect(store.record(for: picture) == nil)
        try store.fileWasWritten(picture, record: record)
        #expect(store.record(for: picture)?.id == record.id)
        // The original is still the first version.
        #expect(PictureFile.loadUpright(store.originalURL(record)).map { pixel($0, 1, 1).r } == 255)
        try store.remove(record)
        #expect(store.records().isEmpty)
        #expect(FileManager.default.fileExists(atPath: picture.path))
    }
}

@Suite struct TextRecognitionTests {
    @Test func readsTheTextInAPicture() {
        let image = makePicture(width: 900, height: 240, text: "HELLO WORLD")
        let text = TextRecognition.recognize(image)
        #expect(text.fullText.uppercased().contains("HELLO"))
        #expect(text.words.count >= 2)
        if let first = text.words.first {
            #expect(first.box.minY > 0.2 && first.box.maxY < 0.9)
        }
    }
}
