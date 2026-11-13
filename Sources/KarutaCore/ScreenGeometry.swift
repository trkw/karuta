import CoreGraphics
import Foundation

/// Coordinate conversions between CoreGraphics, AppKit and ScreenCaptureKit, kept free of AppKit so
/// karuta-check can test them (docs/refactoring.md K20). The app reads the screens and passes their frames.
public enum ScreenGeometry {
    /// A CoreGraphics global rect (top-left origin) in AppKit global coordinates (bottom-left origin),
    /// given the height of the primary screen.
    public static func appKitRect(fromCG rect: CGRect, primaryHeight: CGFloat) -> CGRect {
        CGRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
    }

    /// `rect` (AppKit global coordinates) as ScreenCaptureKit's sourceRect: points relative to the display
    /// whose frame is `screenFrame`, with a top-left origin.
    public static func sourceRect(_ rect: CGRect, screenFrame: CGRect) -> CGRect {
        CGRect(x: rect.minX - screenFrame.minX, y: screenFrame.maxY - rect.maxY, width: rect.width, height: rect.height)
    }
}
