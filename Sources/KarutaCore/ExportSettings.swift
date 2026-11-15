import Foundation
import UniformTypeIdentifiers

/// The numbers used when a capture is written, kept free of AppKit so karuta-check can test them
/// (docs/refactoring.md K5). Exporter does the image work.
public enum ExportSettings {
    /// JPEG and HEIC quality.
    public static let lossyQuality = 0.9

    /// DPI metadata, so Retina captures open at their point size (at full resolution).
    public static func dpi(scale: CGFloat) -> CGFloat { 72 * scale }

    /// Whether the format takes `lossyQuality` (everything but PNG).
    public static func usesQuality(_ type: UTType) -> Bool { type != .png }

    /// The pixel size of a Retina shot scaled down to 1x when that's chosen in Settings, or nil to keep
    /// the shot as it is (the setting is off, it's already 1x, or a side would round to 0).
    public static func oneXSize(width: Int, height: Int, scale: CGFloat, scaleRetina: Bool) -> (width: Int, height: Int)? {
        guard scaleRetina, scale > 1 else { return nil }
        let width = Int((CGFloat(width) / scale).rounded())
        let height = Int((CGFloat(height) / scale).rounded())
        guard width > 0, height > 0 else { return nil }
        return (width, height)
    }
}
