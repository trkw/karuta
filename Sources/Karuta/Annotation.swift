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
        return NSPoint(x: (a.x + b.x) / 2 - dy * 0.25, y: (a.y + b.y) / 2 + dx * 0.25)
    }

    /// The points along a curved arrow, for hit-testing and bounds.
    private static func curvePoints(_ a: NSPoint, _ b: NSPoint) -> [NSPoint] {
        let c = curveControl(a, b)
        return (0 ... 16).map { i in
            let t = CGFloat(i) / 16, u = 1 - t
            return NSPoint(x: u * u * a.x + 2 * u * t * c.x + t * t * b.x, y: u * u * a.y + 2 * u * t * c.y + t * t * b.y)
        }
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
            return NSRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
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
            shaft.curve(to: end, controlPoint1: NSPoint(x: from.x + (control.x - from.x) * 2 / 3,
                                                        y: from.y + (control.y - from.y) * 2 / 3),
                        controlPoint2: NSPoint(x: end.x + (control.x - end.x) * 2 / 3,
                                               y: end.y + (control.y - end.y) * 2 / 3))
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

/// Looks for the editor's tools, stored in `Annotation.style`. Titles are shown in the toolbar.
enum ArrowStyle: Int, CaseIterable {
    case standard, open, double, curved

    var title: String {
        switch self {
        case .standard: "標準"
        case .open: "線の矢じり"
        case .double: "両端"
        case .curved: "曲線"
        }
    }

    var symbol: String {
        switch self {
        case .standard: "arrow.up.right"
        case .open: "chevron.right"
        case .double: "arrow.left.and.right"
        case .curved: "arrow.turn.up.right"
        }
    }
}

enum TextStyle: Int, CaseIterable {
    case outline, box, plain, shadow

    var title: String {
        switch self {
        case .outline: "縁取り"
        case .box: "背景付き"
        case .plain: "文字だけ"
        case .shadow: "影付き"
        }
    }
}

enum PixelateStyle: Int, CaseIterable {
    case mosaic, blackOut

    var title: String { self == .mosaic ? "モザイク" : "黒塗り" }
}

enum CounterStyle: Int, CaseIterable {
    case numbers, upper, lower

    var title: String {
        switch self {
        case .numbers: "1 2 3"
        case .upper: "A B C"
        case .lower: "a b c"
        }
    }

    /// 1 → "1" / "A" / "a"; past Z it goes on AA, AB, … like spreadsheet columns.
    func label(_ n: Int) -> String {
        guard self != .numbers, n > 0 else { return "\(n)" }
        var n = n, result = ""
        let base = self == .upper ? 65 : 97
        while n > 0 {
            n -= 1
            result = String(Character(UnicodeScalar(UInt8(base + n % 26)))) + result
            n /= 26
        }
        return result
    }
}

/// The backdrop behind a shot (CleanShot's Background tool): a gradient, a plain color, the desktop
/// wallpaper or a chosen picture, as set in `Preferences`.
@MainActor
enum Backdrop {
    static func padding(for size: NSSize) -> CGFloat {
        let ratio = CGFloat(Preferences.backdropPadding) / 100
        return (max(12, min(size.width, size.height) * ratio)).rounded()
    }

    static let gradients: [[NSColor]] = [
        [rgb(0x5B45F2), rgb(0x218CFA)],
        [rgb(0xFF5F6D), rgb(0xFFC371)],
        [rgb(0x11998E), rgb(0x38EF7D)],
        [rgb(0xFC466B), rgb(0x3F5EFB)],
        [rgb(0xF7971E), rgb(0xFFD200)],
        [rgb(0x8E2DE2), rgb(0xF64F59)],
        [rgb(0x00C6FB), rgb(0x005BEA)],
        [rgb(0x232526), rgb(0x414345)],
    ]

    private static func rgb(_ hex: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }

    static func drawGradient(_ index: Int, in bounds: NSRect) {
        NSGradient(colors: gradients[gradients.indices.contains(index) ? index : 0])?.draw(in: bounds, angle: -45)
    }

    /// Only the last picture is kept, so switching pictures releases the old one.
    private static var cached: (path: String, image: NSImage)?

    private static func picture() -> NSImage? {
        let url: URL?
        switch Preferences.backdropStyle {
        case .wallpaper: url = NSScreen.main.flatMap { NSWorkspace.shared.desktopImageURL(for: $0) }
        case .image: url = Preferences.backdropImagePath.flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
        default: url = nil
        }
        guard let url else { return nil }
        if let cached, cached.path == url.path { return cached.image }
        guard let image = NSImage(contentsOf: url) else { return nil }
        cached = (url.path, image)
        return image
    }

    static func drawBackground(in bounds: NSRect) {
        switch Preferences.backdropStyle {
        case .gradient:
            drawGradient(Preferences.backdropGradient, in: bounds)
        case .solid:
            Preferences.backdropColor.setFill()
            bounds.fill()
        case .wallpaper, .image:
            guard let image = picture(), image.size.width > 0, image.size.height > 0 else {
                drawGradient(Preferences.backdropGradient, in: bounds) // unreadable picture (e.g. a dynamic wallpaper folder)
                return
            }
            // Fill the area, cropping the picture's overflow like the desktop does.
            let scale = max(bounds.width / image.size.width, bounds.height / image.size.height)
            let size = NSSize(width: image.size.width * scale, height: image.size.height * scale)
            let rect = NSRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2,
                              width: size.width, height: size.height)
            // A base under see-through pictures, so the export matches the editor's preview.
            NSColor.white.setFill()
            bounds.fill()
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(rect: bounds).addClip()
            image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
            NSGraphicsContext.restoreGraphicsState()
        }
    }

    /// Draws `drawImage` clipped to rounded corners with a soft shadow, inside an already-drawn backdrop.
    /// The shadow follows the picture's own alpha, so a window's transparent corners stay see-through.
    static func drawCard(_ rect: NSRect, drawImage: () -> Void) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
        shadow.shadowBlurRadius = 24
        shadow.shadowOffset = NSSize(width: 0, height: -6)
        shadow.set()
        context.beginTransparencyLayer(auxiliaryInfo: nil)
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(roundedRect: rect, xRadius: 10, yRadius: 10).addClip()
        drawImage()
        NSGraphicsContext.restoreGraphicsState()
        context.endTransparencyLayer()
        NSGraphicsContext.restoreGraphicsState()
    }

    /// Wraps a finished shot in the backdrop at the same resolution.
    static func compose(_ shot: Shot) -> Shot {
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
        return context.makeImage().map { Shot(image: $0, scale: shot.scale, app: shot.app) } ?? shot
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
