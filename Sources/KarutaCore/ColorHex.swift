import CoreGraphics
import Foundation

/// How the settings write colours as hex, kept free of AppKit so karuta-check can test it
/// (docs/refactoring.md K28). The strings are what is saved, so they must not change.
public enum ColorHex {
    /// A colour component (sRGB, 0–1) as a byte: kept within 0–1, times 255, rounded.
    public static func byte(_ c: CGFloat) -> UInt32 {
        UInt32((min(max(c, 0), 1) * 255).rounded())
    }

    /// The backdrop colour as saved: "rrggbb", not zero-padded (black is "0").
    public static func rgb(red: CGFloat, green: CGFloat, blue: CGFloat) -> String {
        let value = byte(red) << 16 | byte(green) << 8 | byte(blue)
        return String(value, radix: 16)
    }

    /// A saved editor colour: "rrggbbaa", always 8 digits.
    public static func rgba(red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat) -> String {
        let value = byte(red) << 24 | byte(green) << 16 | byte(blue) << 8 | byte(alpha)
        return String(format: "%08x", value)
    }
}
