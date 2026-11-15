import CoreGraphics
import Foundation

/// The backdrop's sizes, kept free of AppKit so karuta-check can test them (docs/refactoring.md K29).
/// The app reads the setting and passes it in.
public enum BackdropLayout {
    /// The padding around a shot of `size`: `percent` of its shorter side, at least 12pt, rounded.
    public static func padding(percent: Int, size: CGSize) -> CGFloat {
        let ratio = CGFloat(percent) / 100
        return (max(12, min(size.width, size.height) * ratio)).rounded()
    }
}
