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

    /// A scroll's vertical delta: a mouse wheel's coarse steps count 8 times, a trackpad's as they are (K25).
    public static func scrollDelta(_ deltaY: CGFloat, precise: Bool) -> CGFloat {
        precise ? deltaY : deltaY * 8
    }

    /// The opacity after an ⌥-scroll of `delta`, kept between 0.2 and 1.
    public static func opacity(_ current: CGFloat, delta: CGFloat) -> CGFloat {
        min(1, max(0.2, current + delta / 200))
    }

    /// `frame` zoomed by a scroll of `delta`: 1 + delta/300 times as wide (60–4000), `aspect` (height / width)
    /// kept, around the same centre.
    public static func zoomed(_ frame: CGRect, delta: CGFloat, aspect: CGFloat) -> CGRect {
        let width = min(max(frame.width * (1 + delta / 300), 60), 4000)
        let size = CGSize(width: width, height: width * aspect)
        return CGRect(x: frame.midX - size.width / 2, y: frame.midY - size.height / 2,
                      width: size.width, height: size.height)
    }
}
