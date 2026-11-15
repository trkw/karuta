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

    /// The backdrop colour read back: red, green and blue bytes, from any hex that fits in 32 bits (so the
    /// unpadded "0" is black), or nil when it does not read as hex (K31).
    public static func rgbBytes(_ hex: String) -> [UInt32]? {
        guard let value = UInt32(hex, radix: 16) else { return nil }
        return [value >> 16 & 0xFF, value >> 8 & 0xFF, value & 0xFF]
    }

    /// A saved editor colour read back: red, green, blue and alpha bytes from exactly 8 hex digits, or nil.
    public static func rgbaBytes(_ hex: String) -> [UInt32]? {
        guard hex.count == 8, let value = UInt32(hex, radix: 16) else { return nil }
        return [value >> 24 & 0xFF, value >> 16 & 0xFF, value >> 8 & 0xFF, value & 0xFF]
    }
}
