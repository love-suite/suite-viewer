import CoreGraphics
import Foundation
import Testing
@testable import PictureEditCore

private func rect(_ x: Double, _ y: Double, _ w: Double, _ h: Double, kind: Shape.Kind = .rectangle,
                  fill: RGBA? = nil) -> Shape {
    var style = ShapeStyle()
    style.lineWidth = 4
    style.fill = fill
    return Shape(kind: kind, points: [CGPoint(x: x, y: y), CGPoint(x: x + w, y: y + h)], style: style)
}

private func approx(_ a: CGPoint, _ b: CGPoint) -> Bool { abs(a.x - b.x) < 0.001 && abs(a.y - b.y) < 0.001 }

@Suite struct ColourTests {
    @Test func hexRoundTrips() throws {
        #expect(RGBA(hex: "#FF8000")?.hex == "#FF8000FF")
        #expect(RGBA(hex: "00000080")?.alpha == Double(0x80) / 255)
        #expect(RGBA(hex: "nope") == nil)
        let data = try JSONEncoder().encode([RGBA.red])
        #expect(String(decoding: data, as: UTF8.self).contains("#"))
        #expect(try JSONDecoder().decode([RGBA].self, from: data) == [RGBA(hex: RGBA.red.hex)!])
    }
}

@Suite struct GeometryTests {
    let size = CGSize(width: 400, height: 300)

    @Test func canvasSizeFollowsTurns() {
        var doc = EditDocument(imageSize: size)
        doc.rotate(clockwise: true)
        #expect(doc.canvasSize == CGSize(width: 300, height: 400))
        #expect(doc.quarterTurns == 1)
        doc.rotate(clockwise: false)
        #expect(doc.quarterTurns == 0)
        #expect(doc.canvasSize == size)
    }

    @Test func orientationMapsTheTopLeftCorner() {
        var doc = EditDocument(imageSize: size)
        doc.rotate(clockwise: true)
        // Turned clockwise, the top left corner goes to the top right.
        #expect(approx(CGPoint.zero.applying(doc.orientation), CGPoint(x: 300, y: 0)))
        doc = EditDocument(imageSize: size)
        doc.flip()
        #expect(approx(CGPoint.zero.applying(doc.orientation), CGPoint(x: 400, y: 0)))
    }

    /// Whatever the turns and mirrors, a shape stays on the same spot of the picture.
    @Test func shapesFollowThePicture() {
        let pixel = CGPoint(x: 50, y: 70)
        var doc = EditDocument(imageSize: size)
        doc.add(Shape(kind: .line, points: [pixel, pixel], style: ShapeStyle()), to: nil)
        let operations: [(inout EditDocument) -> Void] = [
            { $0.rotate(clockwise: true) }, { $0.flip() }, { $0.rotate(clockwise: true) },
            { $0.flip(horizontally: false) }, { $0.rotate(clockwise: false) }, { $0.flip() },
        ]
        for operation in operations {
            operation(&doc)
            let shape = doc.allShapes[0]
            #expect(approx(shape.points[0], pixel.applying(doc.orientation)))
        }
    }

    @Test func fourTurnsOrTwoFlipsChangeNothing() {
        var doc = EditDocument(imageSize: size)
        doc.add(rect(10, 20, 30, 40), to: nil)
        let before = doc
        for _ in 0..<4 { doc.rotate(clockwise: true) }
        #expect(doc.quarterTurns == 0 && !doc.flipped)
        #expect(approx(doc.allShapes[0].points[0], before.allShapes[0].points[0]))
        doc.flip(); doc.flip()
        #expect(!doc.flipped)
        #expect(approx(doc.allShapes[0].points[1], before.allShapes[0].points[1]))
    }

    @Test func textStaysUprightAndKeepsItsSize() {
        var doc = EditDocument(imageSize: size)
        doc.add(Shape(kind: .text, points: [CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 20)], style: ShapeStyle(),
                      text: "Hi"), to: nil)
        doc.rotate(clockwise: true)
        let frame = doc.allShapes[0].frame
        #expect(frame.size == CGSize(width: 100, height: 20))
        // The centre (50, 10) turned clockwise in a 400 x 300 picture: (300 - 10, 50).
        #expect(approx(CGPoint(x: frame.midX, y: frame.midY), CGPoint(x: 290, y: 50)))
    }

    @Test func cropStaysInsideAndFollowsTurns() {
        var doc = EditDocument(imageSize: size)
        doc.setCrop(CGRect(x: -10, y: 100, width: 200, height: 500))
        #expect(doc.crop == CGRect(x: 0, y: 100, width: 190, height: 200))
        #expect(doc.naturalSize == CGSize(width: 190, height: 200))
        doc.rotate(clockwise: true)
        #expect(doc.naturalSize == CGSize(width: 200, height: 190))
        doc.setCrop(doc.canvasRect)
        #expect(doc.crop == nil)
        #expect(doc.isUnedited == false) // still turned
    }

    @Test func resizeFollowsTurns() {
        var doc = EditDocument(imageSize: size)
        doc.outputSize = CGSize(width: 200, height: 150)
        doc.rotate(clockwise: false)
        #expect(doc.finalSize == CGSize(width: 150, height: 200))
    }
}

@Suite struct LayerTests {
    @Test func addsLayersAboveTheCurrentOne() {
        var doc = EditDocument(imageSize: CGSize(width: 10, height: 10))
        let first = doc.layers[0].id
        let second = doc.addLayer()
        let between = doc.addLayer(above: first)
        #expect(doc.layers.map(\.id) == [first, between, second])
        #expect(doc.layers.map(\.name) == ["Layer 1", "Layer 3", "Layer 2"])
    }

    @Test func movesAndRemovesLayers() {
        var doc = EditDocument(imageSize: CGSize(width: 10, height: 10))
        let first = doc.layers[0].id
        let second = doc.addLayer()
        doc.moveLayer(second, by: -1)
        #expect(doc.layers.map(\.id) == [second, first])
        doc.moveLayer(second, by: -5)
        #expect(doc.layers.map(\.id) == [second, first])
        doc.removeLayer(second)
        #expect(doc.layers.map(\.id) == [first])
        doc.add(rect(0, 0, 1, 1), to: first)
        doc.removeLayer(first)
        #expect(doc.layers.count == 1 && doc.layers[0].shapes.isEmpty)
    }

    @Test func mergeKeepsShapesEditable() {
        var doc = EditDocument(imageSize: CGSize(width: 10, height: 10))
        let bottom = doc.layers[0].id
        doc.add(rect(0, 0, 1, 1), to: bottom)
        let top = doc.addLayer()
        doc.layers[1].opacity = 0.5
        doc.add(rect(2, 2, 1, 1), to: top)
        let merged = doc.mergeDown(top)
        #expect(merged == bottom)
        #expect(doc.layers.count == 1)
        #expect(doc.layers[0].shapes.map(\.style.opacity) == [1, 0.5])
        let none = doc.mergeDown(bottom)
        #expect(none == nil)
    }

    @Test func mergingAHiddenLayerDropsItsShapes() {
        var doc = EditDocument(imageSize: CGSize(width: 10, height: 10))
        let top = doc.addLayer()
        doc.add(rect(2, 2, 1, 1), to: top)
        doc.layers[1].isVisible = false
        doc.mergeDown(top)
        #expect(doc.allShapes.isEmpty)
    }

    @Test func arrangesShapesWithinTheirLayer() {
        var doc = EditDocument(imageSize: CGSize(width: 10, height: 10))
        let a = rect(0, 0, 1, 1), b = rect(1, 1, 1, 1), c = rect(2, 2, 1, 1)
        for shape in [a, b, c] { doc.add(shape, to: nil) }
        doc.arrange(a.id, .front)
        #expect(doc.layers[0].shapes.map(\.id) == [b.id, c.id, a.id])
        doc.arrange(a.id, .backward)
        #expect(doc.layers[0].shapes.map(\.id) == [b.id, a.id, c.id])
        doc.arrange(c.id, .back)
        #expect(doc.layers[0].shapes.map(\.id) == [c.id, b.id, a.id])
        let other = doc.addLayer()
        doc.move(b.id, toLayer: other)
        #expect(doc.layers[1].shapes.map(\.id) == [b.id])
        #expect(doc.locate(b.id)?.layer == 1)
    }

    @Test func stepsCountAndCloseGaps() {
        var doc = EditDocument(imageSize: CGSize(width: 100, height: 100))
        var ids: [UUID] = []
        for i in 0..<3 {
            let step = rect(Double(i) * 10, 0, 8, 8, kind: .step)
            ids.append(step.id)
            doc.add(step, to: nil)
        }
        #expect(doc.allShapes.compactMap(\.number) == [1, 2, 3])
        doc.remove([ids[0]])
        #expect(doc.allShapes.compactMap(\.number) == [1, 2])
        #expect(doc.nextStepNumber == 3)
    }

    @Test func hitTestFindsTheTopmostVisibleShape() {
        var doc = EditDocument(imageSize: CGSize(width: 100, height: 100))
        let below = rect(0, 0, 50, 50, fill: .blue)
        doc.add(below, to: nil)
        let top = doc.addLayer()
        let above = rect(10, 10, 20, 20, fill: .red)
        doc.add(above, to: top)
        #expect(doc.hitTest(CGPoint(x: 15, y: 15), tolerance: 1)?.id == above.id)
        doc.layers[1].isVisible = false
        #expect(doc.hitTest(CGPoint(x: 15, y: 15), tolerance: 1)?.id == below.id)
        #expect(doc.hitTest(CGPoint(x: 90, y: 90), tolerance: 1) == nil)
        #expect(doc.shapes(in: CGRect(x: 40, y: 40, width: 5, height: 5)).map(\.id) == [below.id])
    }

    @Test func isUneditedUntilSomethingChanges() {
        var doc = EditDocument(imageSize: CGSize(width: 10, height: 10))
        #expect(doc.isUnedited)
        doc.addLayer()
        #expect(doc.isUnedited)
        doc.adjustments.contrast = 0.2
        #expect(!doc.isUnedited)
    }
}

@Suite struct ShapeGeometryTests {
    @Test func outlinesAreHitOnTheirStrokeFilledShapesInside() {
        let outline = rect(0, 0, 100, 100)
        #expect(outline.contains(CGPoint(x: 1, y: 50), tolerance: 2))
        #expect(!outline.contains(CGPoint(x: 50, y: 50), tolerance: 2))
        #expect(rect(0, 0, 100, 100, fill: .red).contains(CGPoint(x: 50, y: 50), tolerance: 2))
        let ellipse = rect(0, 0, 100, 50, kind: .ellipse)
        #expect(ellipse.contains(CGPoint(x: 0, y: 25), tolerance: 2))
        #expect(!ellipse.contains(CGPoint(x: 50, y: 25), tolerance: 2))
        #expect(!ellipse.contains(CGPoint(x: 2, y: 2), tolerance: 2))
    }

    @Test func linesAndPathsAreHitNearThem() {
        let line = Shape(kind: .line, points: [CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 0)], style: ShapeStyle())
        #expect(line.contains(CGPoint(x: 50, y: 4), tolerance: 2))
        #expect(!line.contains(CGPoint(x: 50, y: 20), tolerance: 2))
        let pen = Shape(kind: .pen, points: [CGPoint(x: 0, y: 0), CGPoint(x: 10, y: 10), CGPoint(x: 20, y: 0)],
                        style: ShapeStyle())
        #expect(pen.contains(CGPoint(x: 15, y: 5), tolerance: 1))
        #expect(!pen.contains(CGPoint(x: 10, y: 0), tolerance: 1))
    }

    @Test func handlesResize() {
        let shape = rect(0, 0, 100, 50)
        let wider = shape.resizing(.right, to: CGPoint(x: 200, y: 999))
        #expect(wider.frame == CGRect(x: 0, y: 0, width: 200, height: 50))
        let flippedOver = shape.resizing(.left, to: CGPoint(x: 150, y: 0))
        #expect(flippedOver.frame == CGRect(x: 100, y: 0, width: 50, height: 50))
        let kept = shape.resizing(.bottomRight, to: CGPoint(x: 200, y: 60), keepAspect: true)
        #expect(kept.frame == CGRect(x: 0, y: 0, width: 200, height: 100))
        let line = Shape(kind: .arrow, points: [CGPoint(x: 0, y: 0), CGPoint(x: 10, y: 0)], style: ShapeStyle())
        #expect(line.handles == [.end(0), .end(1)])
        #expect(line.resizing(.end(1), to: CGPoint(x: 5, y: 5)).points[1] == CGPoint(x: 5, y: 5))
    }

    @Test func penStrokesScaleWithTheirBox() {
        var style = ShapeStyle()
        style.lineWidth = 0
        let pen = Shape(kind: .pen, points: [CGPoint(x: 0, y: 0), CGPoint(x: 10, y: 10)], style: style)
        let bigger = pen.resizing(.bottomRight, to: CGPoint(x: 20, y: 20))
        #expect(bigger.points == [CGPoint(x: 0, y: 0), CGPoint(x: 20, y: 20)])
    }

    @Test func shiftSnapsAnglesAndSquares() {
        let snapped = Shape.snapAngle(from: .zero, to: CGPoint(x: 100, y: 10))
        #expect(approx(snapped, CGPoint(x: (100.0 * 100 + 10 * 10).squareRoot(), y: 0)))
        #expect(Shape.square(from: .zero, to: CGPoint(x: -30, y: 10)) == CGPoint(x: -30, y: 30))
    }

    @Test func simplifiesPenPoints() {
        let points = (0...100).map { CGPoint(x: Double($0) * 0.1, y: 0) }
        let kept = Shape.simplified(points, spacing: 1)
        #expect(kept.first == points.first && kept.last == points.last)
        #expect(kept.count < 15)
    }
}

@Suite struct HistoryTests {
    @Test func undoesRedoesAndDropsUndoneSteps() {
        var doc = EditDocument(imageSize: CGSize(width: 10, height: 10))
        var history = EditHistory(doc)
        #expect(!history.canUndo)
        doc.add(rect(0, 0, 1, 1), to: nil)
        let recorded = history.record(doc, name: "Rectangle")
        #expect(recorded)
        let again = history.record(doc, name: "Same")
        #expect(!again)
        doc.adjustments.exposure = 0.5
        history.record(doc, name: "Exposure")
        #expect(history.undoName == "Exposure")
        let undone = history.undo()
        #expect(undone?.adjustments.exposure == 0)
        #expect(history.redoName == "Exposure")
        let redone = history.redo()
        #expect(redone?.adjustments.exposure == 0.5)
        history.jump(to: 1)
        doc = history.current
        doc.flip()
        history.record(doc, name: "Flip")
        #expect(history.steps.map(\.name) == ["Original", "Rectangle", "Flip"])
        #expect(!history.canRedo)
    }

    @Test func keepsTheOriginalWhenTrimmed() {
        var doc = EditDocument(imageSize: CGSize(width: 10, height: 10))
        var history = EditHistory(doc, limit: 3)
        for i in 1...5 {
            doc.adjustments.exposure = Double(i) / 10
            history.record(doc, name: "Step \(i)")
        }
        #expect(history.steps.map(\.name) == ["Original", "Step 4", "Step 5"])
        #expect(history.index == 2)
    }

    @Test func roundTripsThroughJSON() throws {
        var doc = EditDocument(imageSize: CGSize(width: 640, height: 480))
        doc.add(Shape(kind: .text, points: [.zero, CGPoint(x: 100, y: 30)], style: ShapeStyle(), text: "Hello"), to: nil)
        doc.add(rect(5, 5, 50, 50, kind: .step), to: nil)
        doc.layers[0].blend = .multiply
        doc.setCrop(CGRect(x: 10, y: 10, width: 300, height: 200))
        var history = EditHistory(EditDocument(imageSize: doc.imageSize))
        history.record(doc, name: "Everything")
        let data = try JSONEncoder().encode(history)
        #expect(try JSONDecoder().decode(EditHistory.self, from: data) == history)
    }

    @Test func readsFilesWithMissingKeys() throws {
        let json = """
        {"id":"\(UUID().uuidString)","kind":"arrow","points":[[0,0],[10,10]],"style":{"stroke":"#00FF00"}}
        """
        let shape = try JSONDecoder().decode(Shape.self, from: Data(json.utf8))
        #expect(shape.style.stroke == RGBA(0, 1, 0))
        #expect(shape.style.lineWidth == ShapeStyle().lineWidth)
        #expect(shape.text == "")
    }
}

@Suite struct RecognizedTextTests {
    let text = RecognizedText(lines: [
        [("Café", CGRect(x: 0.1, y: 0.1, width: 0.1, height: 0.05)),
         ("au", CGRect(x: 0.22, y: 0.1, width: 0.05, height: 0.05)),
         ("lait", CGRect(x: 0.3, y: 0.1, width: 0.1, height: 0.05))],
        [("2,50", CGRect(x: 0.1, y: 0.2, width: 0.1, height: 0.05)),
         ("€", CGRect(x: 0.22, y: 0.2, width: 0.05, height: 0.05))],
    ])

    @Test func joinsWordsAsTheyRead() {
        #expect(text.fullText == "Café au lait\n2,50 €")
        #expect(text.text(in: 1...3) == "au lait\n2,50")
    }

    @Test func findsWordsUnderAndNearAPoint() {
        #expect(text.word(at: CGPoint(x: 0.25, y: 0.12)) == 1)
        #expect(text.word(at: CGPoint(x: 0.9, y: 0.9)) == nil)
        #expect(text.nearestWord(to: CGPoint(x: 0.9, y: 0.12)) == 2)
    }

    @Test func mergesBoxesPerLine() {
        let boxes = text.boxes(for: 1...3)
        #expect(boxes.count == 2)
        #expect(abs(boxes[0].minX - 0.22) < 0.0001 && abs(boxes[0].maxX - 0.4) < 0.0001)
    }

    @Test func searchesIgnoringCaseAndAccents() {
        #expect(text.matches(of: "cafe") == [0...0])
        #expect(text.matches(of: "AU LAIT") == [1...2])
        #expect(text.matches(of: "lait 2,5") == [2...3])
        #expect(text.matches(of: "thé").isEmpty)
        #expect(text.matches(of: " ").isEmpty)
    }
}
