import AppKit
import CoreImage

/// One mark on a screenshot, in image point coordinates (bottom-left origin).
struct Annotation {
    enum Kind {
        case rect(NSRect)
        case filledRect(NSRect)
        case ellipse(NSRect)
        case line(NSPoint, NSPoint)
        case arrow(NSPoint, NSPoint)
        case text(NSPoint, String)
        case counter(NSPoint, Int)
        case pixelate(NSRect)
        case blur(NSRect)
        case spotlight(NSRect)
        case pen([NSPoint])
        case highlighter([NSPoint])
    }

    var kind: Kind
    var color: NSColor
    /// Stroke width in points; text and counters scale with it.
    var width: CGFloat
    /// The tool's look (see `ArrowStyle`, `TextStyle`, `PixelateStyle`, `CounterStyle`); 0 is the default.
    var style: Int = 0

    var textFont: NSFont { .systemFont(ofSize: max(14, width * 5.5), weight: .bold) }
    var counterRadius: CGFloat { 10 + width * 1.2 }
    /// Room around text drawn on a filled box.
    var textPadding: CGFloat { style == TextStyle.box.rawValue ? (textFont.pointSize * 0.3).rounded() : 0 }

    /// The bend of a curved arrow: a point off the middle of the line, a quarter of its length to the left.
    static func curveControl(_ a: NSPoint, _ b: NSPoint) -> NSPoint {
        let dx = b.x - a.x, dy = b.y - a.y
        let x: CGFloat = (a.x + b.x) / 2 - dy * 0.25
        let y: CGFloat = (a.y + b.y) / 2 + dx * 0.25
        return NSPoint(x: x, y: y)
    }

    /// The points along a curved arrow, for hit-testing and bounds.
    private static func curvePoints(_ a: NSPoint, _ b: NSPoint) -> [NSPoint] {
        let c = curveControl(a, b)
        var points: [NSPoint] = []
        for i in 0 ... 16 {
            let t = CGFloat(i) / 16
            let u: CGFloat = 1 - t
            let wa: CGFloat = u * u, wc: CGFloat = 2 * u * t, wb: CGFloat = t * t
            let x: CGFloat = wa * a.x + wc * c.x + wb * b.x
            let y: CGFloat = wa * a.y + wc * c.y + wb * b.y
            points.append(NSPoint(x: x, y: y))
        }
        return points
    }

    private var isCurved: Bool {
        if case .arrow = kind { style == ArrowStyle.curved.rawValue } else { false }
    }

    /// Effects that change the picture itself are drawn under everything else.
    var isImageEffect: Bool {
        switch kind {
        case .pixelate, .blur: true
        default: false
        }
    }

    /// A box around the mark, for hit-testing and selection.
    var bounds: NSRect {
        switch kind {
        case let .rect(r), let .filledRect(r), let .ellipse(r), let .pixelate(r), let .blur(r), let .spotlight(r):
            return r
        case let .line(a, b), let .arrow(a, b):
            let points = isCurved ? Self.curvePoints(a, b) : [a, b]
            let xs = points.map(\.x), ys = points.map(\.y)
            let minX = xs.min() ?? 0, maxX = xs.max() ?? 0, minY = ys.min() ?? 0, maxY = ys.max() ?? 0
            return NSRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
                .insetBy(dx: -width * 2, dy: -width * 2)
        case let .text(p, string):
            let size = (string as NSString).size(withAttributes: [.font: textFont])
            return NSRect(origin: p, size: size).insetBy(dx: -textPadding, dy: -textPadding)
        case let .counter(c, _):
            return NSRect(x: c.x - counterRadius, y: c.y - counterRadius, width: counterRadius * 2, height: counterRadius * 2)
        case let .pen(points), let .highlighter(points):
            let xs = points.map(\.x), ys = points.map(\.y)
            guard let minX = xs.min(), let maxX = xs.max(), let minY = ys.min(), let maxY = ys.max() else { return .zero }
            return NSRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY).insetBy(dx: -width * 2, dy: -width * 2)
        }
    }

    func hitTest(_ point: NSPoint, tolerance: CGFloat) -> Bool {
        switch kind {
        case let .line(a, b), let .arrow(a, b):
            let points = isCurved ? Self.curvePoints(a, b) : [a, b]
            return zip(points, points.dropFirst()).contains {
                Self.distance(from: point, toSegment: $0, $1) <= width / 2 + tolerance
            }
        case let .ellipse(r):
            // Picked by the curved outline: inside the outer ring, outside the inner one.
            func inside(_ inset: CGFloat) -> Bool {
                let rx = r.width / 2 - inset, ry = r.height / 2 - inset
                guard rx > 0, ry > 0 else { return false }
                let dx = (point.x - r.midX) / rx, dy = (point.y - r.midY) / ry
                return dx * dx + dy * dy <= 1
            }
            let slack = width / 2 + tolerance
            return inside(-slack) && !inside(slack)
        case let .rect(r):
            // Outlines are picked by their edge, so marks inside them stay reachable.
            let outer = r.insetBy(dx: -width / 2 - tolerance, dy: -width / 2 - tolerance)
            let inner = r.insetBy(dx: width / 2 + tolerance, dy: width / 2 + tolerance)
            return outer.contains(point) && (inner.isEmpty || !inner.contains(point))
        case let .pen(points), let .highlighter(points):
            return zip(points, points.dropFirst()).contains {
                Self.distance(from: point, toSegment: $0, $1) <= width + tolerance
            }
        default:
            return bounds.insetBy(dx: -tolerance, dy: -tolerance).contains(point)
        }
    }

    func offsetBy(dx: CGFloat, dy: CGFloat) -> Annotation {
        func move(_ p: NSPoint) -> NSPoint { NSPoint(x: p.x + dx, y: p.y + dy) }
        var copy = self
        switch kind {
        case let .rect(r): copy.kind = .rect(r.offsetBy(dx: dx, dy: dy))
        case let .filledRect(r): copy.kind = .filledRect(r.offsetBy(dx: dx, dy: dy))
        case let .ellipse(r): copy.kind = .ellipse(r.offsetBy(dx: dx, dy: dy))
        case let .pixelate(r): copy.kind = .pixelate(r.offsetBy(dx: dx, dy: dy))
        case let .blur(r): copy.kind = .blur(r.offsetBy(dx: dx, dy: dy))
        case let .spotlight(r): copy.kind = .spotlight(r.offsetBy(dx: dx, dy: dy))
        case let .line(a, b): copy.kind = .line(move(a), move(b))
        case let .arrow(a, b): copy.kind = .arrow(move(a), move(b))
        case let .text(p, s): copy.kind = .text(move(p), s)
        case let .counter(p, n): copy.kind = .counter(move(p), n)
        case let .pen(points): copy.kind = .pen(points.map(move))
        case let .highlighter(points): copy.kind = .highlighter(points.map(move))
        }
        return copy
    }

    private static func distance(from p: NSPoint, toSegment a: NSPoint, _ b: NSPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        let lengthSquared = dx * dx + dy * dy
        guard lengthSquared > 0 else { return hypot(p.x - a.x, p.y - a.y) }
        let t = max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / lengthSquared))
        return hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
    }
}

extension NSColor {
    func isSame(as other: NSColor) -> Bool {
        guard let a = usingColorSpace(.sRGB), let b = other.usingColorSpace(.sRGB) else { return false }
        return abs(a.redComponent - b.redComponent) < 0.004 && abs(a.greenComponent - b.greenComponent) < 0.004
            && abs(a.blueComponent - b.blueComponent) < 0.004 && abs(a.alphaComponent - b.alphaComponent) < 0.004
    }

    var isLight: Bool {
        guard let rgb = usingColorSpace(.sRGB) else { return false }
        return 0.299 * rgb.redComponent + 0.587 * rgb.greenComponent + 0.114 * rgb.blueComponent > 0.7
    }
}
