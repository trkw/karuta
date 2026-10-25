import AppKit

/// A capture floating above all windows, like CleanShot's Pin. Drag to move, scroll to zoom,
/// ⌥ + scroll to change opacity, ⌘C to copy, Esc / ⌘W / the close button to close.
final class PinWindow: NSPanel {
    var onClose: (() -> Void)?
    private let shot: Shot
    private let aspect: CGFloat

    init(shot: Shot, frame: NSRect) {
        self.shot = shot
        let pointSize = NSSize(width: CGFloat(shot.image.width) / shot.scale,
                               height: CGFloat(shot.image.height) / shot.scale)
        aspect = pointSize.height / max(pointSize.width, 1)
        // Open at the capture's real size, centred where the overlay card was, but keep it on screen.
        let visible = NSScreen.screens.first { $0.frame.intersects(frame) }?.visibleFrame ?? frame
        let scale = min(1, visible.width * 0.8 / pointSize.width, visible.height * 0.8 / pointSize.height)
        let size = NSSize(width: pointSize.width * scale, height: pointSize.height * scale)
        var origin = NSPoint(x: frame.midX - size.width / 2, y: frame.midY - size.height / 2)
        origin.x = min(max(origin.x, visible.minX), visible.maxX - size.width)
        origin.y = min(max(origin.y, visible.minY), visible.maxY - size.height)

        super.init(contentRect: NSRect(origin: origin, size: size),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = .floating
        hasShadow = true
        isOpaque = false
        backgroundColor = .clear
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        isMovableByWindowBackground = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        contentView = PinView(image: shot.image) { [weak self] in self?.close() }
    }

    override var canBecomeKey: Bool { true }

    override func close() {
        super.close()
        onClose?()
        onClose = nil
    }

    override func scrollWheel(with event: NSEvent) {
        let delta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.scrollingDeltaY * 8
        if event.modifierFlags.contains(.option) {
            alphaValue = min(1, max(0.2, alphaValue + delta / 200))
            return
        }
        let width = min(max(frame.width * (1 + delta / 300), 60), 4000)
        let size = NSSize(width: width, height: width * aspect)
        setFrame(NSRect(x: frame.midX - size.width / 2, y: frame.midY - size.height / 2,
                        width: size.width, height: size.height), display: true)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { close() } else { super.keyDown(with: event) }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command else {
            return super.performKeyEquivalent(with: event)
        }
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "c": Exporter.copy(shot)
        case "w": close()
        default: return super.performKeyEquivalent(with: event)
        }
        return true
    }
}

private final class PinView: NSView {
    private let closeButton = NSButton()
    private let onClose: () -> Void

    init(image: CGImage, onClose: @escaping () -> Void) {
        self.onClose = onClose
        super.init(frame: .zero)
        wantsLayer = true
        layer?.contents = image
        layer?.contentsGravity = .resize
        layer?.cornerRadius = 6
        layer?.masksToBounds = true

        closeButton.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "閉じる")?
            .withSymbolConfiguration(.init(pointSize: 18, weight: .regular))
        closeButton.isBordered = false
        closeButton.contentTintColor = .white
        closeButton.target = self
        closeButton.action = #selector(close)
        closeButton.isHidden = true
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(closeButton)
        NSLayoutConstraint.activate([
            closeButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            closeButton.topAnchor.constraint(equalTo: topAnchor, constant: 6),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    @objc private func close() { onClose() }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self))
    }

    override func mouseEntered(with event: NSEvent) {
        closeButton.isHidden = false
        window?.makeKey()
    }

    override func mouseExited(with event: NSEvent) { closeButton.isHidden = true }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 { onClose() } else { super.mouseDown(with: event) }
    }
}
