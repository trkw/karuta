import CoreGraphics
import Foundation

/// The editor's zoom choices, kept free of AppKit so karuta-check can test them (docs/refactoring.md K33).
public enum EditorZoom {
    /// The zoom menu, in order: a label and a scale (nil fits the window).
    public static let choices: [(label: String, scale: CGFloat?)] = [("フィット", nil), ("50%", 0.5), ("100%", 1), ("200%", 2)]
}
