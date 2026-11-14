import AppKit
import KarutaCore

/// A capture floating above all windows, like CleanShot's Pin. Drag to move, scroll to zoom,
/// ⌥ + scroll to change opacity, arrow keys to nudge (Shift: 10pt), ⌘C to copy,
/// Esc / ⌘W / middle click / the close button to close. The right-click menu also saves, edits,
/// toggles the shadow and locks it (clicks then go through to what's underneath until unlocked).
final class PinWindow: NSPanel {
    var onClose: (() -> Void)?
    var onEdit: ((Shot) -> Void)?
    /// "すべてのピンを閉じる" from the pin's own menu.
    var onCloseAll: (() -> Void)?
    private let shot: Shot
    private let aspect: CGFloat

    init(shot: Shot, frame: NSRect) {
        self.shot = shot
        let pointSize = NSSize(width: CGFloat(shot.image.width) / shot.scale,
                               height: CGFloat(shot.image.height) / shot.scale)
        aspect = pointSize.height / max(pointSize.width, 1)
        // Open at the capture's real size, centred where the overlay card was, but keep it on screen.
        let visible = NSScreen.screens.first { $0.frame.intersects(frame) }?.visibleFrame ?? frame
        let contentRect = PinLayout.frame(pointSize: pointSize, around: frame, visible: visible)

        super.init(contentRect: contentRect,
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = .floating
        hasShadow = true
        isOpaque = false
        backgroundColor = .clear
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        isMovableByWindowBackground = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let view = PinView(image: shot.image) { [weak self] in self?.close() }
        view.menuProvider = { [weak self] in self?.contextMenu() }
        contentView = view
    }

    /// Locked pins let clicks through, so they can sit over something you're working in.
    var isLocked: Bool {
        get { ignoresMouseEvents }
        set {
            guard newValue != ignoresMouseEvents else { return }
            ignoresMouseEvents = newValue
            applyOpacity()
        }
    }

    /// The opacity chosen with ⌥-scroll; while locked it's shown a little see-through as a hint.
    private var opacity: CGFloat = 1

    private func applyOpacity() {
        alphaValue = isLocked ? min(opacity, 0.85) : opacity
    }

    private func contextMenu() -> NSMenu {
        let menu = NSMenu()
        let shot = self.shot
        menu.addItem(MenuAction(title: "コピー") { Exporter.copy(shot) })
        menu.addItem(MenuAction(title: "別名で保存…") { _ = Exporter.saveAs(shot) })
        menu.addItem(MenuAction(title: "編集") { [weak self] in
            guard let self else { return }
            self.onEdit?(shot)
            self.close()
        })
        menu.addItem(.separator())
        let shadow = MenuAction(title: "影を付ける") { [weak self] in
            guard let self else { return }
            self.hasShadow.toggle()
            self.invalidateShadow()
        }
        shadow.state = hasShadow ? .on : .off
        menu.addItem(shadow)
        menu.addItem(MenuAction(title: "ロック（クリックを下に通す）") { [weak self] in self?.isLocked = true })
        menu.addItem(.separator())
        menu.addItem(MenuAction(title: "閉じる") { [weak self] in self?.close() })
        menu.addItem(MenuAction(title: "すべてのピンを閉じる") { [weak self] in self?.onCloseAll?() })
        return menu
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
            opacity = min(1, max(0.2, opacity + delta / 200))
            applyOpacity()
            return
        }
        let width = min(max(frame.width * (1 + delta / 300), 60), 4000)
        let size = NSSize(width: width, height: width * aspect)
        setFrame(NSRect(x: frame.midX - size.width / 2, y: frame.midY - size.height / 2,
                        width: size.width, height: size.height), display: true)
    }

    override func keyDown(with event: NSEvent) {
        let step: CGFloat = event.modifierFlags.contains(.shift) ? 10 : 1
        switch event.keyCode {
        case 53: close()
        case 123: setFrameOrigin(NSPoint(x: frame.minX - step, y: frame.minY))
        case 124: setFrameOrigin(NSPoint(x: frame.minX + step, y: frame.minY))
        case 125: setFrameOrigin(NSPoint(x: frame.minX, y: frame.minY - step))
        case 126: setFrameOrigin(NSPoint(x: frame.minX, y: frame.minY + step))
        default: super.keyDown(with: event)
        }
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
    var menuProvider: (() -> NSMenu?)?
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

    /// Middle click closes, as in CleanShot.
    override func otherMouseDown(with event: NSEvent) {
        if event.buttonNumber == 2 { onClose() } else { super.otherMouseDown(with: event) }
    }

    override func menu(for event: NSEvent) -> NSMenu? { menuProvider?() }
}
