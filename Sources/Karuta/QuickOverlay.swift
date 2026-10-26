import AppKit

/// CleanShot-style Quick Access Overlay: one card per capture, stacked in the bottom-left corner.
/// Hovering a card reveals Copy / Save and corner buttons (close, edit, pin); dragging it drops the
/// file anywhere; a horizontal swipe or the close button dismisses it. The hide button tucks the whole
/// stack behind the screen edge, leaving a small tab that brings it back.
@MainActor
final class QuickOverlay {
    var onEdit: ((Shot) -> Void)?
    var onPin: ((Shot, NSRect) -> Void)?

    private static let maxCards = 5
    private static let spacing: CGFloat = 12
    private static let margin: CGFloat = 16

    private var cards: [OverlayCard] = []
    private var isStackHidden = false
    private var tab: StackTab?

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
        // A new capture always brings a hidden stack back.
        if isStackHidden { setStackHidden(false) }
        // Keep at most maxCards, and drop the oldest cards that would stack above the top of the screen.
        while let excess = cards.count > Self.maxCards ? cards.last : stack().overflow {
            remove(excess, animated: true)
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
        case .hide:
            setStackHidden(true)
        }
    }

    private func setStackHidden(_ hidden: Bool) {
        isStackHidden = hidden
        layout(animated: true)
        updateTab()
    }

    /// The tab sits on the left edge of the newest card's screen, at the middle of its stack.
    private func updateTab() {
        guard isStackHidden, let newest = cards.first else {
            tab?.orderOut(nil)
            tab = nil
            if cards.isEmpty { isStackHidden = false }
            return
        }
        let onScreen = cards.filter { $0.screenFrame == newest.screenFrame }
        let top = (onScreen.map(\.frame.maxY).max() ?? newest.frame.maxY)
        let bottom = newest.screenFrame.minY + Self.margin
        let tab = self.tab ?? StackTab { [weak self] in self?.setStackHidden(false) }
        let size = tab.frame.size
        tab.setFrameOrigin(NSPoint(x: newest.screenFrame.minX, y: ((top + bottom) / 2 - size.height / 2).rounded()))
        tab.setCount(cards.count)
        tab.orderFrontRegardless()
        self.tab = tab
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
        updateTab()
    }

    /// The y of each card (newest at the bottom, per screen), and the oldest card on a screen whose stack
    /// no longer fits below that screen's top edge.
    private func stack() -> (y: [ObjectIdentifier: CGFloat], overflow: OverlayCard?) {
        var y: [ObjectIdentifier: CGFloat] = [:]
        var nextY: [CGFloat: CGFloat] = [:] // per screen (keyed by its minY+minX), the next free y
        var overflow: OverlayCard?
        for card in cards {
            let key = card.screenFrame.minX * 100_000 + card.screenFrame.minY
            let base = nextY[key] ?? card.screenFrame.minY + Self.margin
            y[ObjectIdentifier(card)] = base
            nextY[key] = base + card.frame.height + Self.spacing
            if base > card.screenFrame.minY + Self.margin, base + card.frame.height > card.screenFrame.maxY - Self.margin {
                overflow = cards.last { $0.screenFrame == card.screenFrame }
            }
        }
        return (y, overflow)
    }

    private func layout(animated: Bool) {
        let y = stack().y
        let hidden = isStackHidden
        if !hidden { cards.forEach { $0.orderFrontRegardless() } }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = animated ? 0.25 : 0
            context.allowsImplicitAnimation = true
            for card in cards {
                let x = hidden ? card.screenFrame.minX - card.frame.width - 20 : card.screenFrame.minX + Self.margin
                let origin = NSPoint(x: x, y: y[ObjectIdentifier(card)] ?? 0)
                card.animator().setFrame(NSRect(origin: origin, size: card.frame.size), display: true)
                card.animator().alphaValue = hidden ? 0 : 1
            }
        }, completionHandler: { [weak self] in
            // Off-screen isn't enough: a display to the left would show them. Take them off screen entirely.
            guard let self, self.isStackHidden else { return }
            self.cards.forEach { $0.orderOut(nil) }
        })
    }
}

// MARK: - Card

private final class OverlayCard: NSPanel {
    enum Action {
        case copy, save, edit, pin, close, dropped, swiped, hide
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
        view.onHover = { [weak self] hovering in
            if hovering { self?.stopAutoClose() } else { self?.startAutoClose() }
        }
        contentView = view
        startAutoClose()
    }

    private var autoCloseTimer: Timer?

    /// Closes the card after the delay chosen in Settings; hovering pauses it.
    private func startAutoClose() {
        stopAutoClose()
        let seconds = Preferences.autoCloseSeconds
        guard seconds > 0 else { return }
        autoCloseTimer = Timer.scheduledTimer(withTimeInterval: TimeInterval(seconds), repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.onAction?(.close) }
        }
    }

    private func stopAutoClose() {
        autoCloseTimer?.invalidate()
        autoCloseTimer = nil
    }

    override func orderOut(_ sender: Any?) {
        stopAutoClose()
        super.orderOut(sender)
    }

    /// Becomes key while hovered (without activating the app) so ⌘C / ⌘S / ⌘W / ⌘E work, like CleanShot.
    override var canBecomeKey: Bool { true }
}

private final class CardView: NSView, NSDraggingSource {
    var onAction: ((OverlayCard.Action) -> Void)?
    var makeFile: (() -> URL?)?
    var onHover: ((Bool) -> Void)?

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

        let corners: [(NSImage?, String, OverlayCard.Action, NSLayoutConstraint.Attribute, NSLayoutConstraint.Attribute)] = [
            (CircleButton.symbol("xmark"), "閉じる", .close, .left, .top),
            (CircleButton.symbol("pin.fill"), "ピン留め", .pin, .right, .top),
            (CircleButton.symbol("pencil"), "編集", .edit, .left, .bottom),
            (Self.hideIcon, "スタックを隠す", .hide, .right, .bottom),
        ]
        for (image, label, action, horizontal, vertical) in corners {
            let button = CircleButton(image: image, label: label) { [weak self] in self?.onAction?(action) }
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

    /// A rounded square with its lower-left corner folded in: "tuck the stack away".
    private static let hideIcon: NSImage = {
        let image = NSImage(size: NSSize(width: 12, height: 12), flipped: false) { _ in
            let path = NSBezierPath()
            path.move(to: NSPoint(x: 5, y: 1.5))
            path.line(to: NSPoint(x: 8.5, y: 1.5))
            path.appendArc(from: NSPoint(x: 10.5, y: 1.5), to: NSPoint(x: 10.5, y: 3.5), radius: 2)
            path.line(to: NSPoint(x: 10.5, y: 8.5))
            path.appendArc(from: NSPoint(x: 10.5, y: 10.5), to: NSPoint(x: 8.5, y: 10.5), radius: 2)
            path.line(to: NSPoint(x: 3.5, y: 10.5))
            path.appendArc(from: NSPoint(x: 1.5, y: 10.5), to: NSPoint(x: 1.5, y: 8.5), radius: 2)
            path.line(to: NSPoint(x: 1.5, y: 5))
            path.close()
            path.lineWidth = 1.6
            path.lineJoinStyle = .round
            NSColor.black.setStroke()
            path.stroke()
            let fold = NSBezierPath()
            fold.move(to: NSPoint(x: 1.5, y: 5))
            fold.line(to: NSPoint(x: 5, y: 5))
            fold.line(to: NSPoint(x: 5, y: 1.5))
            fold.close()
            NSColor.black.setFill()
            fold.fill()
            return true
        }
        image.isTemplate = true
        return image
    }()

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self))
    }

    override var acceptsFirstResponder: Bool { true }

    /// Our window that had keyboard focus before hovering (e.g. an editor), restored on exit.
    private weak var previousKeyWindow: NSWindow?

    override func mouseEntered(with event: NSEvent) {
        setHover(true)
        onHover?(true)
        if let key = NSApp.keyWindow, key !== window { previousKeyWindow = key }
        window?.makeKey()
        window?.makeFirstResponder(self)
    }

    override func mouseExited(with event: NSEvent) {
        setHover(false)
        onHover?(false)
        restoreKeyboardFocus()
    }

    /// Shortcuts only apply while hovering: hand keyboard focus back to whoever had it.
    private func restoreKeyboardFocus() {
        guard let window, window.isKeyWindow else { return }
        if let previous = previousKeyWindow, previous.isVisible {
            previous.makeKey()
        } else if !NSApp.isActive, let app = NSWorkspace.shared.frontmostApplication, app != .current {
            app.activate()
        }
        previousKeyWindow = nil
    }

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

/// A small white disc with an SF Symbol, drawn by hand so it stays a perfect circle
/// (a layer-backed NSButton with an image can size itself to the image and title).
private final class CircleButton: ClosureButton {
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

// MARK: - Hidden stack tab

/// The small handle left on the screen edge while the stack is hidden. Click to bring the cards back.
private final class StackTab: NSPanel {
    private let label = NSTextField(labelWithString: "")

    init(onClick: @escaping () -> Void) {
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
        button.frame = NSRect(origin: .zero, size: size)
        button.toolTip = "スタックを表示"
        contentView = button

        label.font = .systemFont(ofSize: 10, weight: .bold)
        label.textColor = .white
        label.alignment = .center
        label.frame = NSRect(x: 0, y: 8, width: size.width - 2, height: 14)
        button.addSubview(label)
    }

    func setCount(_ count: Int) {
        label.stringValue = "\(count)"
    }
}

private final class TabButton: ClosureButton {
    override func draw(_ dirtyRect: NSRect) {
        // Rounded on the right only (the left part is clipped by the view): it sticks out of the screen edge.
        NSColor(white: 0.12, alpha: 0.9).setFill()
        NSBezierPath(roundedRect: NSRect(x: -12, y: 0, width: bounds.width + 12, height: bounds.height),
                     xRadius: 10, yRadius: 10).fill()
        let chevron = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: "スタックを表示")?
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
