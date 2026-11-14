import CoreGraphics
import Foundation

/// Where a pin window opens, kept free of AppKit so karuta-check can test it (docs/refactoring.md K24).
/// The app finds the screen and passes its visible frame.
public enum PinLayout {
    /// Open at the capture's real size (`pointSize`), centred where the overlay card was (`card`), but keep it
    /// on screen: shrunk to fit 80% of `visible`, then pushed inside it.
    public static func frame(pointSize: CGSize, around card: CGRect, visible: CGRect) -> CGRect {
        let scale = min(1, visible.width * 0.8 / pointSize.width, visible.height * 0.8 / pointSize.height)
        let size = CGSize(width: pointSize.width * scale, height: pointSize.height * scale)
        var origin = CGPoint(x: card.midX - size.width / 2, y: card.midY - size.height / 2)
        origin.x = min(max(origin.x, visible.minX), visible.maxX - size.width)
        origin.y = min(max(origin.y, visible.minY), visible.maxY - size.height)
        return CGRect(origin: origin, size: size)
    }
}
