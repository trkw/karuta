import Foundation

/// The pixel size of a screen recording, kept free of AppKit so karuta-check can test it
/// (docs/refactoring.md K16).
public enum RecordingSize {
    /// The pixel size to record at: H.264 tops out around 4096 × 2304, so bigger areas are scaled down,
    /// and both sides must be even.
    public static func output(points: CGSize, scale: CGFloat) -> (width: Int, height: Int) {
        var width = points.width * scale, height = points.height * scale
        let fit = min(1, 4096 / max(width, 1), 2304 / max(height, 1))
        width *= fit
        height *= fit
        return (max(2, Int(width) / 2 * 2), max(2, Int(height) / 2 * 2))
    }
}
