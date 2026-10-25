import AppKit

/// CleanShot-style Quick Access Overlay: one card per capture, stacked in the bottom-left corner.
/// Hovering a card reveals Copy / Save and corner buttons (close, edit, pin); dragging it drops the
/// file anywhere; a horizontal swipe or the close button dismisses it.
@MainActor
final class QuickOverlay {
    var onEdit: ((Shot) -> Void)?
    var onPin: ((Shot, NSRect) -> Void)?

    private static let maxCards = 5
    private static let spacing: CGFloat = 12
    private static let margin: CGFloat = 16

    private var cards: [OverlayCard] = []

    func show(_ shot: Shot, on screen: NSScreen) {
        let card = OverlayCard(shot: shot, screen: screen)
        card.onAction = { [weak self, weak card] action in
            guard let self, let card else { return }
            self.handle(action, for: card)
        }
        // New cards slide in from the left edge at the bottom; older ones move up.
        let target = NSPoint(x: screen.visibleFrame.minX + Self.margin, y: screen.visibleFrame.minY + Self.margin)
        card.setFrameOrigin(NSPoint(x: screen.visibleFrame.minX - card.frame.width, y: target.y))
        card.alphaValue = 0
        card.orderFrontRegardless()
        cards.insert(card, at: 0)
        while cards.count > Self.maxCards, let oldest = cards.last {
            remove(oldest, animated: true)
        }
        layout(animated: true)
    }

    private func handle(_ action: OverlayCard.Action, for card: OverlayCard) {
        switch action {
        case .copy:
            Exporter.copy(card.shot)
            remove(card, animated: true)
        case .save:
            do {
                try Exporter.save(card.shot)
                remove(card, animated: true)
            } catch {
                let alert = NSAlert(error: error)
                alert.messageText = "保存できませんでした"
                NSApp.activate()
                alert.runModal()
            }
        case .edit:
            remove(card, animated: false)
            onEdit?(card.shot)
        case .pin:
            remove(card, animated: false)
            onPin?(card.shot, card.frame)
        case .close, .dropped:
            remove(card, animated: true)
        case .swiped:
            remove(card, animated: true, slideOut: true)
        }
    }

    private func remove(_ card: OverlayCard, animated: Bool, slideOut: Bool = false) {
        cards.removeAll { $0 === card }
        if animated {
            var frame = card.frame
            if slideOut { frame.origin.x = card.screenFrame.minX - frame.width }
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.2
                card.animator().alphaValue = 0
                card.animator().setFrame(frame, display: true)
            }, completionHandler: {
                card.orderOut(nil)
            })
        } else {
            card.orderOut(nil)
        }
        layout(animated: animated)
    }

    private func layout(animated: Bool) {
        var y: [ObjectIdentifier: CGFloat] = [:]
        var nextY: [CGFloat: CGFloat] = [:] // per screen (keyed by its minY+minX), the next free y
        for card in cards {
            let key = card.screenFrame.minX * 100_000 + card.screenFrame.minY
            let base = nextY[key] ?? card.screenFrame.minY + Self.margin
            y[ObjectIdentifier(card)] = base
            nextY[key] = base + card.frame.height + Self.spacing
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = animated ? 0.25 : 0
            context.allowsImplicitAnimation = true
            for card in cards {
                let origin = NSPoint(x: card.screenFrame.minX + Self.margin, y: y[ObjectIdentifier(card)] ?? 0)
                card.animator().setFrame(NSRect(origin: origin, size: card.frame.size), display: true)
                card.animator().alphaValue = 1
            }
        }
    }
}

// MARK: - Card

private final class OverlayCard: NSPanel {
    enum Action {
        case copy, save, edit, pin, close, dropped, swiped
    }

    let shot: Shot
    /// The visible frame of the screen the card lives on.
    let screenFrame: NSRect
    var onAction: ((Action) -> Void)?

    init(shot: Shot, screen: NSScreen) {
        self.shot = shot
        screenFrame = screen.visibleFrame

        let width: CGFloat = 220
        let aspect = CGFloat(shot.image.height) / CGFloat(max(shot.image.width, 1))
        let size = NSSize(width: width, height: min(max(width * aspect, 90), 220))

        super.init(contentRect: NSRect(origin: .zero, size: size),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = .floating
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let view = CardView(frame: NSRect(origin: .zero, size: size), image: shot.image)
        view.onAction = { [weak self] action in self?.onAction?(action) }
        view.makeFile = { [weak self] in self.flatMap { Exporter.writeTemporary($0.shot) } }
        contentView = view
    }

    /// Becomes key while hovered (without activating the app) so ⌘C / ⌘S / ⌘W / ⌘E work, like CleanShot.
    override var canBecomeKey: Bool { true }
}

private final class CardView: NSView, NSDraggingSource {
    var onAction: ((OverlayCard.Action) -> Void)?
    var makeFile: (() -> URL?)?

    private let image: CGImage
    private let hoverLayer = NSView()
    private var mouseDownPoint: NSPoint?
    private var isDragging = false
    private var swipeDistance: CGFloat = 0

    init(frame: NSRect, image: CGImage) {
        self.image = image
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.masksToBounds = true
        layer?.backgroundColor = NSColor(white: 0.12, alpha: 1).cgColor
        layer?.borderWidth = 1
        layer?.borderColor = NSColor(white: 1, alpha: 0.15).cgColor

        let imageLayer = CALayer()
        imageLayer.frame = bounds
        imageLayer.contents = image
        imageLayer.contentsGravity = .resizeAspect
        imageLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        layer?.addSublayer(imageLayer)

        buildHoverControls()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func buildHoverControls() {
        hoverLayer.frame = bounds
        hoverLayer.autoresizingMask = [.width, .height]
        hoverLayer.wantsLayer = true
        hoverLayer.layer?.backgroundColor = NSColor(white: 0, alpha: 0.45).cgColor
        hoverLayer.alphaValue = 0
        addSubview(hoverLayer)

        let copy = PillButton(title: "コピー") { [weak self] in self?.onAction?(.copy) }
        let save = PillButton(title: "保存") { [weak self] in self?.onAction?(.save) }
        let stack = NSStackView(views: [copy, save])
        stack.orientation = .vertical
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        hoverLayer.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: hoverLayer.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: hoverLayer.centerYAnchor),
            copy.widthAnchor.constraint(equalToConstant: 96),
            save.widthAnchor.constraint(equalToConstant: 96),
        ])

        let corners: [(String, String, OverlayCard.Action, NSLayoutConstraint.Attribute, NSLayoutConstraint.Attribute)] = [
            ("xmark", "閉じる", .close, .left, .top),
            ("pin.fill", "ピン留め", .pin, .right, .top),
            ("pencil", "編集", .edit, .left, .bottom),
        ]
        for (symbol, label, action, horizontal, vertical) in corners {
            let button = CircleButton(symbol: symbol, label: label) { [weak self] in self?.onAction?(action) }
            button.translatesAutoresizingMaskIntoConstraints = false
            hoverLayer.addSubview(button)
            NSLayoutConstraint.activate([
                NSLayoutConstraint(item: button, attribute: horizontal, relatedBy: .equal,
                                   toItem: hoverLayer, attribute: horizontal, multiplier: 1,
                                   constant: horizontal == .left ? 6 : -6),
                NSLayoutConstraint(item: button, attribute: vertical, relatedBy: .equal,
                                   toItem: hoverLayer, attribute: vertical, multiplier: 1,
                                   constant: vertical == .top ? 6 : -6),
            ])
        }
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self))
    }

    override var acceptsFirstResponder: Bool { true }

    override func mouseEntered(with event: NSEvent) {
        setHover(true)
        window?.makeKey()
        window?.makeFirstResponder(self)
    }

    override func mouseExited(with event: NSEvent) { setHover(false) }

    private func setHover(_ on: Bool) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            hoverLayer.animator().alphaValue = on ? 1 : 0
        }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command else {
            return super.performKeyEquivalent(with: event)
        }
        let actions: [String: OverlayCard.Action] = ["c": .copy, "s": .save, "w": .close, "e": .edit, "p": .pin]
        guard let key = event.charactersIgnoringModifiers?.lowercased(), let action = actions[key] else {
            return super.performKeyEquivalent(with: event)
        }
        onAction?(action)
        return true
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onAction?(.close) } else { super.keyDown(with: event) }
    }

    override func mouseDown(with event: NSEvent) {
        mouseDownPoint = event.locationInWindow
        if event.clickCount == 2 { onAction?(.edit) }
    }

    override func mouseDragged(with event: NSEvent) {
        guard !isDragging, let start = mouseDownPoint,
              hypot(event.locationInWindow.x - start.x, event.locationInWindow.y - start.y) > 4,
              let url = makeFile?()
        else { return }
        isDragging = true
        let item = NSDraggingItem(pasteboardWriter: url as NSURL)
        item.setDraggingFrame(bounds, contents: NSImage(cgImage: image, size: bounds.size))
        beginDraggingSession(with: [item], event: event, source: self)
    }

    /// Two-finger horizontal swipe dismisses the card, as in CleanShot.
    override func scrollWheel(with event: NSEvent) {
        guard event.hasPreciseScrollingDeltas else { return super.scrollWheel(with: event) }
        if event.phase == .began { swipeDistance = 0 }
        if abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) {
            swipeDistance += event.scrollingDeltaX
        }
        if abs(swipeDistance) > 60 {
            swipeDistance = 0
            onAction?(.swiped)
        }
    }

    func draggingSession(_ session: NSDraggingSession,
                         sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .copy
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        isDragging = false
        mouseDownPoint = nil
        if !operation.isEmpty { onAction?(.dropped) }
    }
}

// MARK: - Buttons

/// Buttons inside non-activating panels need to react to the first click.
private class ClosureButton: NSButton {
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

private final class PillButton: ClosureButton {
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

private final class CircleButton: ClosureButton {
    init(symbol: String, label: String, handler: @escaping () -> Void) {
        super.init(handler: handler)
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)?
            .withSymbolConfiguration(.init(pointSize: 10, weight: .bold))
        contentTintColor = .black
        toolTip = label
        layer?.backgroundColor = NSColor(white: 1, alpha: 0.92).cgColor
        layer?.cornerRadius = 11
        widthAnchor.constraint(equalToConstant: 22).isActive = true
        heightAnchor.constraint(equalToConstant: 22).isActive = true
    }
}
