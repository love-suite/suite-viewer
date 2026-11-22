import CoreGraphics
import Foundation

/// Where a shape can be grabbed to reshape it.
public enum Handle: Hashable, Sendable {
    /// One of a line's or an arrow's two ends.
    case end(Int)
    case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left
}

extension Shape {
    /// The rectangle framed shapes fill (two corners, in any order).
    public var frame: CGRect {
        guard let first = points.first else { return .null }
        let last = points.count > 1 ? points[points.count - 1] : first
        return CGRect(x: min(first.x, last.x), y: min(first.y, last.y),
                      width: abs(last.x - first.x), height: abs(last.y - first.y))
    }

    /// Everything the shape covers, its stroke included.
    public var bounds: CGRect {
        guard !points.isEmpty else { return .null }
        var rect: CGRect
        if kind.isPath || kind.isSegment {
            let xs = points.map(\.x), ys = points.map(\.y)
            rect = CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
        } else {
            rect = frame
        }
        let outset: Double = switch kind {
        case .arrow: style.lineWidth * 3
        case .rectangle, .ellipse, .line, .pen, .highlighter: style.lineWidth / 2
        default: 0
        }
        return rect.insetBy(dx: -outset, dy: -outset)
    }

    /// The shape moved by `offset`.
    public func moved(by offset: CGVector) -> Shape {
        var shape = self
        shape.points = points.map { CGPoint(x: $0.x + offset.dx, y: $0.y + offset.dy) }
        return shape
    }

    /// The shape under a transform of the whole picture (a turn or a mirror). Text, step markers and
    /// pictures follow with their centre but stay upright and keep their size.
    public func applying(_ transform: CGAffineTransform) -> Shape {
        var shape = self
        if kind.staysUpright {
            let rect = frame
            let center = CGPoint(x: rect.midX, y: rect.midY).applying(transform)
            shape.points = [CGPoint(x: center.x - rect.width / 2, y: center.y - rect.height / 2),
                            CGPoint(x: center.x + rect.width / 2, y: center.y + rect.height / 2)]
        } else {
            shape.points = points.map { $0.applying(transform) }
        }
        return shape
    }

    /// The handles this shape offers.
    public var handles: [Handle] {
        if kind.isSegment { return [.end(0), .end(1)] }
        if kind == .step { return [.topLeft, .topRight, .bottomRight, .bottomLeft] }
        return [.topLeft, .top, .topRight, .right, .bottomRight, .bottom, .bottomLeft, .left]
    }

    /// Where a handle sits.
    public func location(of handle: Handle) -> CGPoint {
        let r = kind.isPath ? bounds.insetBy(dx: style.lineWidth / 2, dy: style.lineWidth / 2) : frame
        switch handle {
        case .end(let i): return points[min(i, points.count - 1)]
        case .topLeft: return CGPoint(x: r.minX, y: r.minY)
        case .top: return CGPoint(x: r.midX, y: r.minY)
        case .topRight: return CGPoint(x: r.maxX, y: r.minY)
        case .right: return CGPoint(x: r.maxX, y: r.midY)
        case .bottomRight: return CGPoint(x: r.maxX, y: r.maxY)
        case .bottom: return CGPoint(x: r.midX, y: r.maxY)
        case .bottomLeft: return CGPoint(x: r.minX, y: r.maxY)
        case .left: return CGPoint(x: r.minX, y: r.midY)
        }
    }

    /// The shape with `handle` dragged to `point`. `keepAspect` keeps its proportions (Shift); step
    /// markers and pictures always keep them.
    public func resizing(_ handle: Handle, to point: CGPoint, keepAspect: Bool = false) -> Shape {
        var shape = self
        if case .end(let i) = handle {
            var target = point
            if keepAspect, points.count == 2 { target = Self.snapAngle(from: points[1 - i], to: point) }
            shape.points[min(i, points.count - 1)] = target
            return shape
        }
        let old = kind.isPath ? bounds.insetBy(dx: style.lineWidth / 2, dy: style.lineWidth / 2) : frame
        var minX = old.minX, minY = old.minY, maxX = old.maxX, maxY = old.maxY
        switch handle {
        case .topLeft: minX = point.x; minY = point.y
        case .top: minY = point.y
        case .topRight: maxX = point.x; minY = point.y
        case .right: maxX = point.x
        case .bottomRight: maxX = point.x; maxY = point.y
        case .bottom: maxY = point.y
        case .bottomLeft: minX = point.x; maxY = point.y
        case .left: minX = point.x
        case .end: break
        }
        var new = CGRect(x: min(minX, maxX), y: min(minY, maxY), width: abs(maxX - minX), height: abs(maxY - minY))
        if (keepAspect || kind == .step || kind == .picture), old.width > 0, old.height > 0 {
            new = Self.keepingAspect(of: old, in: new, anchoredOpposite: handle)
        }
        return shape.fitted(from: old, to: new)
    }

    /// Points scaled from one rectangle to another.
    func fitted(from old: CGRect, to new: CGRect) -> Shape {
        var shape = self
        let sx = old.width > 0 ? new.width / old.width : 1
        let sy = old.height > 0 ? new.height / old.height : 1
        shape.points = points.map {
            CGPoint(x: new.minX + ($0.x - old.minX) * sx, y: new.minY + ($0.y - old.minY) * sy)
        }
        if old.width == 0 || old.height == 0, kind.isPath == false, points.count == 2 {
            shape.points = [CGPoint(x: new.minX, y: new.minY), CGPoint(x: new.maxX, y: new.maxY)]
        }
        return shape
    }

    /// `rect` reshaped to `old`'s proportions, keeping the corner or side opposite the handle in place.
    static func keepingAspect(of old: CGRect, in rect: CGRect, anchoredOpposite handle: Handle) -> CGRect {
        let ratio = old.width / old.height
        var width = rect.width, height = rect.height
        switch handle {
        case .top, .bottom: width = height * ratio
        case .left, .right: height = width / ratio
        default: if width / max(height, 0.0001) > ratio { height = width / ratio } else { width = height * ratio }
        }
        let anchorX: Double, anchorY: Double
        switch handle {
        case .topLeft: anchorX = old.maxX - width; anchorY = old.maxY - height
        case .topRight: anchorX = old.minX; anchorY = old.maxY - height
        case .bottomLeft: anchorX = old.maxX - width; anchorY = old.minY
        case .bottomRight: anchorX = old.minX; anchorY = old.minY
        case .top: anchorX = old.midX - width / 2; anchorY = old.maxY - height
        case .bottom: anchorX = old.midX - width / 2; anchorY = old.minY
        case .left: anchorX = old.maxX - width; anchorY = old.midY - height / 2
        case .right: anchorX = old.minX; anchorY = old.midY - height / 2
        case .end: anchorX = rect.minX; anchorY = rect.minY
        }
        return CGRect(x: anchorX, y: anchorY, width: width, height: height)
    }

    /// `point` moved so the line from `origin` is horizontal, vertical or at 45° (Shift while drawing).
    public static func snapAngle(from origin: CGPoint, to point: CGPoint) -> CGPoint {
        let dx = point.x - origin.x, dy = point.y - origin.y
        let length = hypot(dx, dy)
        guard length > 0 else { return point }
        let angle = (atan2(dy, dx) / (.pi / 4)).rounded() * (.pi / 4)
        return CGPoint(x: origin.x + cos(angle) * length, y: origin.y + sin(angle) * length)
    }

    /// The corner opposite `origin` making a square (Shift while drawing a rectangle or an ellipse).
    public static func square(from origin: CGPoint, to point: CGPoint) -> CGPoint {
        let dx = point.x - origin.x, dy = point.y - origin.y
        let side = max(abs(dx), abs(dy))
        return CGPoint(x: origin.x + (dx < 0 ? -side : side), y: origin.y + (dy < 0 ? -side : side))
    }

    /// Whether `point` touches the shape: on the stroke of outlines, anywhere inside filled shapes.
    public func contains(_ point: CGPoint, tolerance: Double) -> Bool {
        let reach = tolerance + style.lineWidth / 2
        switch kind {
        case .line, .arrow:
            guard points.count == 2 else { return false }
            return Self.distance(from: point, toSegment: points[0], points[1]) <= reach + (kind == .arrow ? style.lineWidth : 0)
        case .pen, .highlighter:
            if points.count == 1 { return hypot(point.x - points[0].x, point.y - points[0].y) <= reach }
            return zip(points, points.dropFirst()).contains { Self.distance(from: point, toSegment: $0, $1) <= reach }
        case .rectangle:
            let outer = frame.insetBy(dx: -reach, dy: -reach)
            guard outer.contains(point) else { return false }
            if style.fill != nil { return true }
            let inner = frame.insetBy(dx: reach, dy: reach)
            return inner.isNull || inner.width <= 0 || inner.height <= 0 || !inner.contains(point)
        case .ellipse:
            let r = frame
            guard r.width > 0, r.height > 0 else { return false }
            let rx = r.width / 2, ry = r.height / 2
            let nx = (point.x - r.midX), ny = (point.y - r.midY)
            let value = (nx * nx) / (rx * rx) + (ny * ny) / (ry * ry)
            if style.fill != nil { return value <= 1 + reach / min(rx, ry) }
            // Near the outline: compare against ellipses grown and shrunk by the reach.
            let outer = (nx * nx) / pow(rx + reach, 2) + (ny * ny) / pow(ry + reach, 2)
            let innerRx = rx - reach, innerRy = ry - reach
            if innerRx <= 0 || innerRy <= 0 { return outer <= 1 }
            let inner = (nx * nx) / (innerRx * innerRx) + (ny * ny) / (innerRy * innerRy)
            return outer <= 1 && inner >= 1
        case .step:
            let r = frame
            return hypot(point.x - r.midX, point.y - r.midY) <= max(r.width, r.height) / 2 + tolerance
        case .text, .blur, .pixelate, .redact, .picture:
            return frame.insetBy(dx: -tolerance, dy: -tolerance).contains(point)
        }
    }

    static func distance(from p: CGPoint, toSegment a: CGPoint, _ b: CGPoint) -> Double {
        let dx = b.x - a.x, dy = b.y - a.y
        let lengthSquared = dx * dx + dy * dy
        guard lengthSquared > 0 else { return hypot(p.x - a.x, p.y - a.y) }
        let t = min(max(((p.x - a.x) * dx + (p.y - a.y) * dy) / lengthSquared, 0), 1)
        return hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
    }

    /// Pen strokes thinned to points at least `spacing` apart, keeping the ends.
    public static func simplified(_ points: [CGPoint], spacing: Double) -> [CGPoint] {
        guard points.count > 2 else { return points }
        var kept = [points[0]]
        for point in points.dropFirst().dropLast() {
            let last = kept[kept.count - 1]
            if hypot(point.x - last.x, point.y - last.y) >= spacing { kept.append(point) }
        }
        kept.append(points[points.count - 1])
        return kept
    }
}
