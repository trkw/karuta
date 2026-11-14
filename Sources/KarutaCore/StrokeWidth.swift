import CoreGraphics
import Foundation

/// The editor's stroke widths, kept free of AppKit so karuta-check can test them (docs/refactoring.md K23).
public enum StrokeWidth {
    /// The widths, thin to thick. Keys 1–6 pick them.
    public static let steps: [CGFloat] = [1, 2, 4, 6, 8, 12]

    /// The width for a typed key, when it is one of 1–6.
    public static func forKey(_ key: String) -> CGFloat? {
        guard let digit = Int(key), (1 ... 6).contains(digit) else { return nil }
        return steps[digit - 1]
    }
}
