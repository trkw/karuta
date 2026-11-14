import AppKit
import KarutaCore

/// The backdrop behind a shot (CleanShot's Background tool): a gradient, a plain color, the desktop
/// wallpaper or a chosen picture, as set in `Preferences`.
@MainActor
enum Backdrop {
    static func padding(for size: NSSize) -> CGFloat {
        BackdropLayout.padding(percent: Preferences.backdropPadding, size: size)
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
