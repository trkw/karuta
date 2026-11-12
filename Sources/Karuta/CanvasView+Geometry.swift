import AppKit

// Geometry: the document and zoom sizes, and converting between image and view points.
extension CanvasView {
    var fullRect: NSRect { NSRect(origin: .zero, size: renderer.size) }
    var editingCrop: Bool { tool == .crop }
    /// The part of the image shown (the crop, unless the crop itself is being edited).
    var shownArea: NSRect { editingCrop ? fullRect : (crop ?? fullRect) }
    var padding: CGFloat { background && !editingCrop ? Backdrop.padding(for: shownArea.size) : 0 }
    var documentSize: NSSize {
        NSSize(width: shownArea.width + padding * 2, height: shownArea.height + padding * 2)
    }

    private var availableSize: NSSize { enclosingScrollView?.contentSize ?? bounds.size }

    var fitZoom: CGFloat {
        let area = availableSize
        return max(0.05, min(1, (area.width - 48) / documentSize.width, (area.height - 48) / documentSize.height))
    }

    var zoom: CGFloat { zoomLevel ?? fitZoom }

    var documentRect: NSRect {
        let size = NSSize(width: documentSize.width * zoom, height: documentSize.height * zoom)
        return NSRect(x: ((bounds.width - size.width) / 2).rounded(), y: ((bounds.height - size.height) / 2).rounded(),
                      width: size.width, height: size.height)
    }

    /// Grows the view past the scroll view when zoomed in, so it can be scrolled.
    func updateFrame() {
        let area = availableSize
        let size = NSSize(width: max(area.width, documentSize.width * zoom + 48),
                          height: max(area.height, documentSize.height * zoom + 48))
        if frame.size != size { setFrameSize(size) }
        needsDisplay = true
    }

    func viewPoint(_ p: NSPoint) -> NSPoint {
        let doc = documentRect
        return NSPoint(x: doc.minX + (padding + p.x - shownArea.minX) * zoom,
                       y: doc.minY + (padding + p.y - shownArea.minY) * zoom)
    }

    func viewRect(_ r: NSRect) -> NSRect {
        let origin = viewPoint(r.origin)
        return NSRect(x: origin.x, y: origin.y, width: r.width * zoom, height: r.height * zoom)
    }

    func imagePoint(for event: NSEvent, clamp: Bool = true) -> NSPoint {
        let v = convert(event.locationInWindow, from: nil)
        let doc = documentRect
        var p = NSPoint(x: (v.x - doc.minX) / zoom - padding + shownArea.minX,
                        y: (v.y - doc.minY) / zoom - padding + shownArea.minY)
        if clamp {
            let area = shownArea
            p.x = min(max(p.x, area.minX), area.maxX)
            p.y = min(max(p.y, area.minY), area.maxY)
        }
        return p
    }
}
