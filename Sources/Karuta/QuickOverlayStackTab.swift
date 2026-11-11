import AppKit

// MARK: - Hidden stack tab

/// The small handle left on the screen edge while the stack is hidden. Click to bring the cards back.
final class StackTab: NSPanel {
    let onRight: Bool
    private let label = NSTextField(labelWithString: "")

    init(onRight: Bool, onClick: @escaping () -> Void) {
        self.onRight = onRight
        let size = NSSize(width: 22, height: 64)
        super.init(contentRect: NSRect(origin: .zero, size: size),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = .floating
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let button = TabButton(handler: onClick)
        button.onRight = onRight
        button.frame = NSRect(origin: .zero, size: size)
        button.toolTip = "スタックを表示"
        contentView = button

        label.font = .systemFont(ofSize: 10, weight: .bold)
        label.textColor = .white
        label.alignment = .center
        label.frame = NSRect(x: onRight ? 2 : 0, y: 8, width: size.width - 2, height: 14)
        button.addSubview(label)
    }

    func setCount(_ count: Int) {
        label.stringValue = "\(count)"
    }
}

private final class TabButton: ClosureButton {
    var onRight = false

    override func draw(_ dirtyRect: NSRect) {
        // Rounded on the inner side only (the outer part is clipped by the view): it sticks out of the screen edge.
        NSColor(white: 0.12, alpha: 0.9).setFill()
        NSBezierPath(roundedRect: NSRect(x: onRight ? 0 : -12, y: 0, width: bounds.width + 12, height: bounds.height),
                     xRadius: 10, yRadius: 10).fill()
        let chevron = NSImage(systemSymbolName: onRight ? "chevron.left" : "chevron.right",
                              accessibilityDescription: "スタックを表示")?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .bold))
        if let chevron {
            let tinted = NSImage(size: chevron.size, flipped: false) { rect in
                chevron.draw(in: rect)
                NSColor.white.set()
                rect.fill(using: .sourceAtop)
                return true
            }
            let size = chevron.size
            tinted.draw(in: NSRect(x: (bounds.midX - size.width / 2).rounded(), y: (bounds.midY + 2).rounded(),
                                   width: size.width, height: size.height))
        }
    }
}
