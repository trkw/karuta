import AppKit

// Drawing the canvas: the image, the annotations, the crop and the size label.
extension CanvasView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor(white: 0.13, alpha: 1).setFill()
        bounds.fill()
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let doc = documentRect
        let visible = shownArea
        let marks = annotations + (preview.map { [$0] } ?? [])

        context.saveGState()
        context.translateBy(x: doc.minX, y: doc.minY)
        context.scaleBy(x: zoom, y: zoom)
        let drawImage = {
            context.saveGState()
            context.translateBy(x: self.padding - visible.minX, y: self.padding - visible.minY)
            context.clip(to: visible)
            self.renderer.draw(marks)
            context.restoreGState()
        }
        if padding > 0 {
            Backdrop.drawBackground(in: NSRect(origin: .zero, size: documentSize))
            Backdrop.drawCard(NSRect(x: padding, y: padding, width: visible.width, height: visible.height), drawImage: drawImage)
        } else {
            NSGraphicsContext.saveGraphicsState()
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.5)
            shadow.shadowBlurRadius = 12
            shadow.set()
            NSColor.black.setFill()
            NSRect(origin: .zero, size: visible.size).fill()
            NSGraphicsContext.restoreGraphicsState()
            drawImage()
        }
        context.restoreGState()

        if editingCrop, let crop {
            let area = viewRect(crop)
            let dim = NSBezierPath(rect: viewRect(fullRect))
            dim.append(NSBezierPath(rect: area))
            dim.windingRule = .evenOdd
            NSColor.black.withAlphaComponent(0.55).setFill()
            dim.fill()
            NSColor.white.setStroke()
            let border = NSBezierPath(rect: area.insetBy(dx: 0.5, dy: 0.5))
            border.lineWidth = 1
            border.stroke()
            drawSizeLabel(crop.size, below: area)
        }

        if let index = selected, annotations.indices.contains(index) {
            let box = viewRect(annotations[index].bounds).insetBy(dx: -4, dy: -4)
            let path = NSBezierPath(roundedRect: box, xRadius: 3, yRadius: 3)
            path.lineWidth = 1
            path.setLineDash([4, 3], count: 2, phase: 0)
            NSColor.controlAccentColor.setStroke()
            path.stroke()
        }
    }

    private func drawSizeLabel(_ size: NSSize, below rect: NSRect) {
        let text = "\(Int(size.width)) × \(Int(size.height))" as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium), .foregroundColor: NSColor.white,
        ]
        let textSize = text.size(withAttributes: attributes)
        let box = NSRect(x: rect.midX - textSize.width / 2 - 6, y: rect.minY - textSize.height - 12,
                         width: textSize.width + 12, height: textSize.height + 4)
        NSColor.black.withAlphaComponent(0.75).setFill()
        NSBezierPath(roundedRect: box, xRadius: box.height / 2, yRadius: box.height / 2).fill()
        text.draw(at: NSPoint(x: box.minX + 6, y: box.minY + 2), withAttributes: attributes)
    }
}
