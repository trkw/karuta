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

    var textFont: NSFont { .systemFont(ofSize: max(14, width * 5.5), weight: .bold) }
    var counterRadius: CGFloat { 10 + width * 1.2 }

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
            return NSRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
                .insetBy(dx: -width * 2, dy: -width * 2)
        case let .text(p, string):
            let size = (string as NSString).size(withAttributes: [.font: textFont])
            return NSRect(origin: p, size: size)
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
            return Self.distance(from: point, toSegment: a, b) <= width / 2 + tolerance
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

/// Draws a shot and its annotations in image point coordinates (bottom-left origin) into the current
/// NSGraphicsContext. Shared by the on-screen canvas and the export, so both look the same.
@MainActor
final class AnnotationRenderer {
    let shot: Shot
    let size: NSSize
    private var pixelated: CGImage?
    private var blurred: CGImage?

    init(shot: Shot) {
        self.shot = shot
        size = NSSize(width: CGFloat(shot.image.width) / shot.scale, height: CGFloat(shot.image.height) / shot.scale)
    }

    func draw(_ annotations: [Annotation]) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.interpolationQuality = .high
        context.draw(shot.image, in: NSRect(origin: .zero, size: size))
        // Picture effects first, then the spotlight dimming, then marks on top.
        for annotation in annotations where annotation.isImageEffect {
            draw(annotation, in: context)
        }
        let spotlights = annotations.compactMap { annotation -> NSRect? in
            if case let .spotlight(r) = annotation.kind { return r } else { return nil }
        }
        if !spotlights.isEmpty {
            // Dim in a layer and clear each spot, so overlapping spots stay bright.
            context.saveGState()
            context.beginTransparencyLayer(auxiliaryInfo: nil)
            context.setFillColor(NSColor.black.withAlphaComponent(0.55).cgColor)
            context.fill(NSRect(origin: .zero, size: size))
            context.setBlendMode(.clear)
            for spot in spotlights {
                context.addPath(CGPath(roundedRect: spot, cornerWidth: 6, cornerHeight: 6, transform: nil))
            }
            context.fillPath()
            context.endTransparencyLayer()
            context.restoreGState()
        }
        for annotation in annotations where !annotation.isImageEffect {
            draw(annotation, in: context)
        }
    }

    /// Bakes the annotations into a new image at the original resolution, then crops it.
    func render(_ annotations: [Annotation], crop: NSRect?) -> Shot {
        var result = shot
        if !annotations.isEmpty, let context = Self.bitmap(width: shot.image.width, height: shot.image.height,
                                                          space: shot.image.colorSpace) {
            context.scaleBy(x: shot.scale, y: shot.scale)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
            draw(annotations)
            NSGraphicsContext.restoreGraphicsState()
            if let image = context.makeImage() { result = Shot(image: image, scale: shot.scale) }
        }
        if let crop {
            let pixels = CGRect(x: crop.minX * shot.scale, y: (size.height - crop.maxY) * shot.scale,
                                width: crop.width * shot.scale, height: crop.height * shot.scale).integral
            if let cropped = result.image.cropping(to: pixels) { result = Shot(image: cropped, scale: shot.scale) }
        }
        return result
    }

    static func bitmap(width: Int, height: Int, space: CGColorSpace?) -> CGContext? {
        let colorSpace = space.flatMap { $0.supportsOutput ? $0 : nil } ?? CGColorSpace(name: CGColorSpace.sRGB)!
        return CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        )
    }

    private func draw(_ annotation: Annotation, in context: CGContext) {
        let color = annotation.color
        let width = annotation.width
        switch annotation.kind {
        case let .rect(rect):
            color.setStroke()
            let path = NSBezierPath(roundedRect: rect, xRadius: width, yRadius: width)
            path.lineWidth = width
            path.stroke()
        case let .filledRect(rect):
            color.setFill()
            NSBezierPath(roundedRect: rect, xRadius: width, yRadius: width).fill()
        case let .ellipse(rect):
            color.setStroke()
            let path = NSBezierPath(ovalIn: rect)
            path.lineWidth = width
            path.stroke()
        case let .line(from, to):
            color.setStroke()
            let path = NSBezierPath()
            path.move(to: from)
            path.line(to: to)
            path.lineWidth = width
            path.lineCapStyle = .round
            path.stroke()
        case let .arrow(from, to):
            drawArrow(from: from, to: to, color: color, width: width)
        case let .text(point, string):
            (string as NSString).draw(at: point, withAttributes: Self.textAttributes(color, font: annotation.textFont))
        case let .counter(center, n):
            let radius = annotation.counterRadius
            color.setFill()
            NSBezierPath(ovalIn: NSRect(x: center.x - radius, y: center.y - radius,
                                        width: radius * 2, height: radius * 2)).fill()
            let label = "\(n)" as NSString
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: radius * 1.15, weight: .bold),
                .foregroundColor: color.isLight ? NSColor.black : NSColor.white,
            ]
            let size = label.size(withAttributes: attributes)
            label.draw(at: NSPoint(x: center.x - size.width / 2, y: center.y - size.height / 2),
                       withAttributes: attributes)
        case let .pixelate(rect):
            drawEffect(pixelatedImage(), in: rect, context: context, smooth: false)
        case let .blur(rect):
            drawEffect(blurredImage(), in: rect, context: context, smooth: true)
        case .spotlight:
            break // drawn together in draw(_:)
        case let .pen(points):
            stroke(points, color: color, width: width)
        case let .highlighter(points):
            stroke(points, color: color.withAlphaComponent(0.35), width: width * 4, butt: true)
        }
    }

    private func stroke(_ points: [NSPoint], color: NSColor, width: CGFloat, butt: Bool = false) {
        guard let first = points.first else { return }
        let path = NSBezierPath()
        path.move(to: first)
        points.dropFirst().forEach { path.line(to: $0) }
        if points.count == 1 { path.line(to: first) }
        path.lineWidth = width
        path.lineCapStyle = butt ? .square : .round
        path.lineJoinStyle = .round
        color.setStroke()
        path.stroke()
    }

    private func drawEffect(_ image: CGImage?, in rect: NSRect, context: CGContext, smooth: Bool) {
        guard let image else { return }
        context.saveGState()
        context.clip(to: rect)
        context.interpolationQuality = smooth ? .high : .none
        context.draw(image, in: NSRect(origin: .zero, size: size))
        context.restoreGState()
    }

    static func textAttributes(_ color: NSColor, font: NSFont) -> [NSAttributedString.Key: Any] {
        [
            .font: font,
            .foregroundColor: color,
            .strokeColor: color.isLight ? NSColor.black : NSColor.white,
            .strokeWidth: -3, // negative: fill and outline
        ]
    }

    private func drawArrow(from: NSPoint, to: NSPoint, color: NSColor, width: CGFloat) {
        let length = hypot(to.x - from.x, to.y - from.y)
        guard length > 1 else { return }
        let angle = atan2(to.y - from.y, to.x - from.x)
        let head = min(width * 5, length * 0.6)
        let spread: CGFloat = 0.45

        color.setStroke()
        let shaft = NSBezierPath()
        shaft.lineWidth = width
        shaft.lineCapStyle = .round
        shaft.move(to: from)
        shaft.line(to: NSPoint(x: to.x - cos(angle) * head * 0.7, y: to.y - sin(angle) * head * 0.7))
        shaft.stroke()

        color.setFill()
        let tip = NSBezierPath()
        tip.move(to: to)
        tip.line(to: NSPoint(x: to.x - head * cos(angle - spread), y: to.y - head * sin(angle - spread)))
        tip.line(to: NSPoint(x: to.x - head * cos(angle + spread), y: to.y - head * sin(angle + spread)))
        tip.close()
        tip.fill()
    }

    /// The whole image shrunk to 12pt blocks; pixelated regions draw it back without interpolation.
    /// Built once on first use, so it costs nothing unless the tool is used.
    private func pixelatedImage() -> CGImage? {
        if let pixelated { return pixelated }
        let block = 12 * shot.scale
        let width = max(1, Int(CGFloat(shot.image.width) / block))
        let height = max(1, Int(CGFloat(shot.image.height) / block))
        guard let context = Self.bitmap(width: width, height: height, space: nil) else { return nil }
        context.interpolationQuality = .medium
        context.draw(shot.image, in: CGRect(x: 0, y: 0, width: width, height: height))
        pixelated = context.makeImage()
        return pixelated
    }

    /// A Gaussian-blurred copy of the whole image, built on first use.
    private func blurredImage() -> CGImage? {
        if let blurred { return blurred }
        let input = CIImage(cgImage: shot.image)
        let output = input.clampedToExtent().applyingGaussianBlur(sigma: 10 * shot.scale).cropped(to: input.extent)
        blurred = CIContext(options: [.cacheIntermediates: false]).createCGImage(output, from: input.extent)
        return blurred
    }
}

/// CleanShot-style background: the screenshot on a gradient with padding, rounded corners and a shadow.
enum Backdrop {
    static func padding(for size: NSSize) -> CGFloat {
        (max(24, min(size.width, size.height) * 0.08)).rounded()
    }

    static let colors = [NSColor(srgbRed: 0.36, green: 0.27, blue: 0.95, alpha: 1),
                         NSColor(srgbRed: 0.13, green: 0.55, blue: 0.98, alpha: 1)]

    /// Draws the backdrop for an image of `imageSize` placed at `imageOrigin` (the whole area is `bounds`).
    static func drawBackground(in bounds: NSRect) {
        NSGradient(colors: colors)?.draw(in: bounds, angle: -45)
    }

    /// Draws `drawImage` clipped to rounded corners with a soft shadow, inside an already-drawn backdrop.
    static func drawCard(_ rect: NSRect, drawImage: () -> Void) {
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
        shadow.shadowBlurRadius = 24
        shadow.shadowOffset = NSSize(width: 0, height: -6)
        shadow.set()
        NSColor.black.setFill()
        NSBezierPath(roundedRect: rect, xRadius: 10, yRadius: 10).fill()
        NSGraphicsContext.restoreGraphicsState()

        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(roundedRect: rect, xRadius: 10, yRadius: 10).addClip()
        drawImage()
        NSGraphicsContext.restoreGraphicsState()
    }

    /// Wraps a finished shot in the backdrop at the same resolution.
    @MainActor static func compose(_ shot: Shot) -> Shot {
        let size = NSSize(width: CGFloat(shot.image.width) / shot.scale, height: CGFloat(shot.image.height) / shot.scale)
        let pad = padding(for: size)
        let total = NSSize(width: size.width + pad * 2, height: size.height + pad * 2)
        guard let context = AnnotationRenderer.bitmap(width: Int((total.width * shot.scale).rounded()),
                                                     height: Int((total.height * shot.scale).rounded()),
                                                     space: shot.image.colorSpace)
        else { return shot }
        context.scaleBy(x: shot.scale, y: shot.scale)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        drawBackground(in: NSRect(origin: .zero, size: total))
        let rect = NSRect(x: pad, y: pad, width: size.width, height: size.height)
        drawCard(rect) { context.draw(shot.image, in: rect) }
        NSGraphicsContext.restoreGraphicsState()
        return context.makeImage().map { Shot(image: $0, scale: shot.scale) } ?? shot
    }
}

extension NSColor {
    var isLight: Bool {
        guard let rgb = usingColorSpace(.sRGB) else { return false }
        return 0.299 * rgb.redComponent + 0.587 * rgb.greenComponent + 0.114 * rgb.blueComponent > 0.7
    }
}
