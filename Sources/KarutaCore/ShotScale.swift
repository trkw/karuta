import CoreGraphics
import Foundation

/// Guessing a shot's scale (pixels per point) for images that come from outside a capture, kept free of
/// AppKit so karuta-check can test it (docs/refactoring.md K30).
public enum ShotScale {
    /// A pasted image: its pixel width over its point width, rounded, at least 1. A width of 0 points counts as 1.
    public static func fromPixels(pixelWidth: Int, pointWidth: CGFloat) -> CGFloat {
        max(1, CGFloat(pixelWidth) / max(pointWidth, 1)).rounded()
    }

    /// An image file: its DPI over 72, rounded, at least 1.
    public static func fromDPI(_ dpi: Double) -> CGFloat {
        max(1, (CGFloat(dpi) / 72).rounded())
    }
}
