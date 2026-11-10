import AppKit
import UniformTypeIdentifiers

// MARK: - Controls

/// A toolbar tool: an SF Symbol that turns into white-on-blue when active, like CleanShot.
final class ToolButton: NSButton {
    var isOn = false { didSet { needsDisplay = true } }
    private let symbol: NSImage?
    private let handler: () -> Void

    init(symbol name: String, label: String, handler: @escaping () -> Void) {
        symbol = NSImage(systemSymbolName: name, accessibilityDescription: label)?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .medium))
        self.handler = handler
        super.init(frame: .zero)
        title = ""
        isBordered = false
        toolTip = label
        setAccessibilityLabel(label)
        target = self
        action = #selector(fire)
        widthAnchor.constraint(equalToConstant: 32).isActive = true
        heightAnchor.constraint(equalToConstant: 26).isActive = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    @objc private func fire() { handler() }

    override func draw(_ dirtyRect: NSRect) {
        if isOn {
            NSColor.controlAccentColor.setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 6, yRadius: 6).fill()
        }
        guard let symbol else { return }
        let tint: NSColor = isOn ? .white : .labelColor
        let tinted = NSImage(size: symbol.size, flipped: false) { rect in
            symbol.draw(in: rect)
            tint.set()
            rect.fill(using: .sourceAtop)
            return true
        }
        tinted.draw(in: NSRect(x: (bounds.midX - symbol.size.width / 2).rounded(),
                               y: (bounds.midY - symbol.size.height / 2).rounded(),
                               width: symbol.size.width, height: symbol.size.height))
    }
}

final class CapsuleView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor.labelColor.withAlphaComponent(0.08).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8).fill()
    }
}

/// The bottom bar's background with a hairline on top.
final class BarView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor(white: 0.18, alpha: 1).setFill()
        bounds.fill()
        NSColor(white: 1, alpha: 0.08).setFill()
        NSRect(x: 0, y: bounds.maxY - 1, width: bounds.width, height: 1).fill()
    }
}

/// A round dark button with a symbol (share, pin, copy).
final class RoundIconButton: NSButton {
    private let symbol: NSImage?
    private let handler: (NSView) -> Void

    init(symbol name: String, label: String, handler: @escaping (NSView) -> Void) {
        symbol = NSImage(systemSymbolName: name, accessibilityDescription: label)?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .semibold))
        self.handler = handler
        super.init(frame: .zero)
        title = ""
        isBordered = false
        toolTip = label
        setAccessibilityLabel(label)
        target = self
        action = #selector(fire)
        widthAnchor.constraint(equalToConstant: 34).isActive = true
        heightAnchor.constraint(equalToConstant: 28).isActive = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    @objc private func fire() { handler(self) }

    override func draw(_ dirtyRect: NSRect) {
        NSColor(white: 1, alpha: isHighlighted ? 0.2 : 0.1).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2).fill()
        guard let symbol else { return }
        let tinted = NSImage(size: symbol.size, flipped: false) { rect in
            symbol.draw(in: rect)
            NSColor.white.set()
            rect.fill(using: .sourceAtop)
            return true
        }
        tinted.draw(in: NSRect(x: (bounds.midX - symbol.size.width / 2).rounded(),
                               y: (bounds.midY - symbol.size.height / 2).rounded(),
                               width: symbol.size.width, height: symbol.size.height))
    }
}

/// "Drag Me": drag the edited image out as a file.
final class DragHandle: NSView, NSDraggingSource {
    private let makeFile: () -> URL?

    init(makeFile: @escaping () -> URL?) {
        self.makeFile = makeFile
        super.init(frame: .zero)
        toolTip = "ドラッグして他のアプリへ渡す"
        widthAnchor.constraint(equalToConstant: 150).isActive = true
        heightAnchor.constraint(equalToConstant: 28).isActive = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .openHand)
    }

    override func draw(_ dirtyRect: NSRect) {
        let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: bounds.height / 2,
                                 yRadius: bounds.height / 2)
        NSColor(white: 1, alpha: 0.06).setFill()
        shape.fill()
        NSColor(white: 1, alpha: 0.15).setStroke()
        shape.stroke()

        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium), .foregroundColor: NSColor.secondaryLabelColor,
        ]
        let text = "Drag Me" as NSString
        let size = text.size(withAttributes: attributes)
        text.draw(at: NSPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2), withAttributes: attributes)
        // Grip lines on both sides.
        NSColor.tertiaryLabelColor.setFill()
        for x in [bounds.minX + 16, bounds.maxX - 26] {
            for i in 0 ..< 3 {
                NSRect(x: x, y: bounds.midY - 4 + CGFloat(i) * 4, width: 10, height: 1).fill()
            }
        }
    }

    override func mouseDown(with event: NSEvent) {}

    override func mouseDragged(with event: NSEvent) {
        guard let url = makeFile() else { return }
        let item = NSDraggingItem(pasteboardWriter: url as NSURL)
        let icon = NSImage(contentsOf: url) ?? NSImage()
        let width: CGFloat = 120
        let height = icon.size.width > 0 ? width * icon.size.height / icon.size.width : width
        let point = convert(event.locationInWindow, from: nil)
        item.setDraggingFrame(NSRect(x: point.x - width / 2, y: point.y - height / 2, width: width, height: height),
                              contents: icon)
        beginDraggingSession(with: [item], event: event, source: self)
    }

    func draggingSession(_ session: NSDraggingSession,
                         sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .copy
    }
}
