import CoreGraphics
import Foundation

/// Where a Quick Access card sits, kept free of AppKit so karuta-check can test it (docs/refactoring.md K21).
public enum CardLayout {
    /// The card's x: just inside its side of the screen (`margin` from the edge), or (hidden) just past that
    /// edge, `gap` beyond it.
    public static func x(
        screenFrame screen: CGRect, cardWidth: CGFloat, onRight: Bool, hidden: Bool, margin: CGFloat, gap: CGFloat
    ) -> CGFloat {
        if onRight {
            return hidden ? screen.maxX + gap : screen.maxX - margin - cardWidth
        }
        return hidden ? screen.minX - cardWidth - gap : screen.minX + margin
    }
}
