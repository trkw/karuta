import CoreGraphics
import Foundation

/// Where the scrolling capture's panel sits, kept free of AppKit so karuta-check can test it
/// (docs/refactoring.md K27). The app finds the screen and passes its visible frame.
public enum PanelLayout {
    /// The panel's origin: centred 12pt under `area`; above it when that would leave `visible` at the bottom;
    /// 12pt up from the area's bottom when it would still leave at the top (the area fills the screen); and
    /// 8pt in from the screen's sides.
    public static func scrollPanelOrigin(below area: CGRect, panelSize: CGSize, visible: CGRect) -> CGPoint {
        var origin = CGPoint(x: area.midX - panelSize.width / 2, y: area.minY - panelSize.height - 12)
        if origin.y < visible.minY { origin.y = min(area.maxY + 12, visible.maxY - panelSize.height) }
        if origin.y + panelSize.height > visible.maxY { origin.y = area.minY + 12 } // area fills the screen: inside it
        origin.x = min(max(origin.x, visible.minX + 8), visible.maxX - panelSize.width - 8)
        return origin
    }
}
