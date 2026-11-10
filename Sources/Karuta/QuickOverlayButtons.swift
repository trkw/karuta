import AppKit

// MARK: - Buttons

/// Buttons inside non-activating panels need to react to the first click.
class ClosureButton: NSButton {
    private let handler: () -> Void

    init(handler: @escaping () -> Void) {
        self.handler = handler
        super.init(frame: .zero)
        target = self
        action = #selector(fire)
        isBordered = false
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    @objc private func fire() { handler() }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

final class PillButton: ClosureButton {
    init(title: String, handler: @escaping () -> Void) {
        super.init(handler: handler)
        attributedTitle = NSAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
            .foregroundColor: NSColor.black,
        ])
        layer?.backgroundColor = NSColor(white: 1, alpha: 0.92).cgColor
        layer?.cornerRadius = 13
        heightAnchor.constraint(equalToConstant: 26).isActive = true
    }
}

/// A small white disc with an SF Symbol, drawn by hand so it stays a perfect circle
/// (a layer-backed NSButton with an image can size itself to the image and title).
final class CircleButton: ClosureButton {
    private static let diameter: CGFloat = 24
    private let symbol: NSImage?

    static func symbol(_ name: String) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 10, weight: .bold))
    }

    init(image: NSImage?, label: String, handler: @escaping () -> Void) {
        symbol = image
        super.init(handler: handler)
        title = ""
        imagePosition = .noImage
        toolTip = label
        setAccessibilityLabel(label)
        widthAnchor.constraint(equalToConstant: Self.diameter).isActive = true
        heightAnchor.constraint(equalToConstant: Self.diameter).isActive = true
    }

    override var intrinsicContentSize: NSSize { NSSize(width: Self.diameter, height: Self.diameter) }

    override func draw(_ dirtyRect: NSRect) {
        let side = min(bounds.width, bounds.height)
        let circle = NSRect(x: bounds.midX - side / 2, y: bounds.midY - side / 2, width: side, height: side)
        NSColor(white: 1, alpha: 0.95).setFill()
        NSBezierPath(ovalIn: circle).fill()
        guard let symbol else { return }
        let tinted = NSImage(size: symbol.size, flipped: false) { rect in
            symbol.draw(in: rect)
            NSColor.black.set()
            rect.fill(using: .sourceAtop)
            return true
        }
        let size = symbol.size
        tinted.draw(in: NSRect(x: (bounds.midX - size.width / 2).rounded(), y: (bounds.midY - size.height / 2).rounded(),
                               width: size.width, height: size.height))
    }
}
