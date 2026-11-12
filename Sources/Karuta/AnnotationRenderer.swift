import AppKit
import CoreImage

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
            if let image = context.makeImage() { result = Shot(image: image, scale: shot.scale, app: shot.app) }
        }
        if let crop {
            let pixels = CGRect(x: crop.minX * shot.scale, y: (size.height - crop.maxY) * shot.scale,
                                width: crop.width * shot.scale, height: crop.height * shot.scale).integral
            if let cropped = result.image.cropping(to: pixels) { result = Shot(image: cropped, scale: shot.scale, app: shot.app) }
        }
        return result
    }

    nonisolated static func bitmap(width: Int, height: Int, space: CGColorSpace?) -> CGContext? {
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
            drawArrow(from: from, to: to, color: color, width: width,
                      style: ArrowStyle(rawValue: annotation.style) ?? .standard)
        case let .text(point, string):
            drawText(string, at: point, annotation: annotation)
        case let .counter(center, n):
            let radius = annotation.counterRadius
            color.setFill()
            NSBezierPath(ovalIn: NSRect(x: center.x - radius, y: center.y - radius,
                                        width: radius * 2, height: radius * 2)).fill()
            let label = (CounterStyle(rawValue: annotation.style) ?? .numbers).label(n) as NSString
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: radius * 1.15, weight: .bold),
                .foregroundColor: color.isLight ? NSColor.black : NSColor.white,
            ]
            let size = label.size(withAttributes: attributes)
            label.draw(at: NSPoint(x: center.x - size.width / 2, y: center.y - size.height / 2),
                       withAttributes: attributes)
        case let .pixelate(rect) where annotation.style == PixelateStyle.blackOut.rawValue:
            NSColor.black.setFill()
            rect.fill()
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

    private func drawText(_ string: String, at point: NSPoint, annotation: Annotation) {
        let font = annotation.textFont
        let color = annotation.color
        switch TextStyle(rawValue: annotation.style) ?? .outline {
        case .outline:
            (string as NSString).draw(at: point, withAttributes: Self.textAttributes(color, font: font))
        case .box:
            color.setFill()
            let box = annotation.bounds
            NSBezierPath(roundedRect: box, xRadius: annotation.textPadding, yRadius: annotation.textPadding).fill()
            (string as NSString).draw(at: point, withAttributes: [
                .font: font, .foregroundColor: color.isLight ? NSColor.black : NSColor.white,
            ])
        case .plain:
            (string as NSString).draw(at: point, withAttributes: [.font: font, .foregroundColor: color])
        case .shadow:
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.6)
            shadow.shadowBlurRadius = font.pointSize * 0.15
            shadow.shadowOffset = NSSize(width: 0, height: -font.pointSize * 0.06)
            (string as NSString).draw(at: point, withAttributes: [.font: font, .foregroundColor: color, .shadow: shadow])
        }
    }

    private func drawArrow(from: NSPoint, to: NSPoint, color: NSColor, width: CGFloat, style: ArrowStyle) {
        let length = hypot(to.x - from.x, to.y - from.y)
        guard length > 1 else { return }
        let head = min(width * 5, length * (style == .double ? 0.4 : 0.6))
        let spread: CGFloat = 0.45
        color.setStroke()
        color.setFill()

        /// A filled triangle at `tip`, pointing along `angle`; returns where the shaft should stop.
        func filledHead(at tip: NSPoint, angle: CGFloat) -> NSPoint {
            let path = NSBezierPath()
            path.move(to: tip)
            path.line(to: NSPoint(x: tip.x - head * cos(angle - spread), y: tip.y - head * sin(angle - spread)))
            path.line(to: NSPoint(x: tip.x - head * cos(angle + spread), y: tip.y - head * sin(angle + spread)))
            path.close()
            path.fill()
            return NSPoint(x: tip.x - cos(angle) * head * 0.7, y: tip.y - sin(angle) * head * 0.7)
        }

        let shaft = NSBezierPath()
        shaft.lineWidth = width
        shaft.lineCapStyle = .round
        shaft.lineJoinStyle = .round
        switch style {
        case .standard:
            let end = filledHead(at: to, angle: atan2(to.y - from.y, to.x - from.x))
            shaft.move(to: from)
            shaft.line(to: end)
        case .open:
            let angle = atan2(to.y - from.y, to.x - from.x)
            shaft.move(to: from)
            shaft.line(to: to)
            shaft.move(to: NSPoint(x: to.x - head * cos(angle - spread), y: to.y - head * sin(angle - spread)))
            shaft.line(to: to)
            shaft.line(to: NSPoint(x: to.x - head * cos(angle + spread), y: to.y - head * sin(angle + spread)))
        case .double:
            let angle = atan2(to.y - from.y, to.x - from.x)
            let end = filledHead(at: to, angle: angle)
            let start = filledHead(at: from, angle: angle + .pi)
            shaft.move(to: start)
            shaft.line(to: end)
        case .curved:
            let control = Annotation.curveControl(from, to)
            // The head follows the curve's direction where it arrives.
            let end = filledHead(at: to, angle: atan2(to.y - control.y, to.x - control.x))
            shaft.move(to: from)
            // A quadratic curve written as a cubic one: each control point is 2/3 of the way to the bend.
            func toward(_ p: NSPoint) -> NSPoint {
                NSPoint(x: p.x + (control.x - p.x) * 2 / 3, y: p.y + (control.y - p.y) * 2 / 3)
            }
            shaft.curve(to: end, controlPoint1: toward(from), controlPoint2: toward(end))
        }
        shaft.stroke()
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
