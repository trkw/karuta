import CoreGraphics
import Foundation

/// The shapes the editor draws from a drag, kept free of AppKit so karuta-check can test them
/// (docs/refactoring.md K19).
public enum DrawGeometry {
    /// The rectangle between the drag's start and end, from its lower corner whatever the direction.
    /// With `square` (Shift) both sides take the longer one, keeping the drag's direction.
    public static func rect(from a: CGPoint, to b: CGPoint, square: Bool) -> CGRect {
        var dx = b.x - a.x, dy = b.y - a.y
        if square {
            let side = max(abs(dx), abs(dy))
            dx = dx < 0 ? -side : side
            dy = dy < 0 ? -side : side
        }
        return CGRect(x: min(a.x, a.x + dx), y: min(a.y, a.y + dy), width: abs(dx), height: abs(dy))
    }

    /// Shift: lock lines to 45° steps, keeping their length.
    public static func snap(_ p: CGPoint, from start: CGPoint) -> CGPoint {
        let dx = p.x - start.x, dy = p.y - start.y
        let length = hypot(dx, dy)
        let angle = (atan2(dy, dx) / (.pi / 4)).rounded() * (.pi / 4)
        return CGPoint(x: start.x + cos(angle) * length, y: start.y + sin(angle) * length)
    }
}
