import AppKit
import KarutaCore

// MARK: - Card

final class OverlayCard: NSPanel {
    enum Action {
        case copy, save, saveAs, edit, pin, close, dropped, swiped, hide, saveAll, closeAll
    }

    let shot: Shot
    var original: Shot?
    /// The visible frame of the screen the card lives on.
    let screenFrame: NSRect
    /// Which side of the screen it stacks on (Settings, at the time it was shown).
    let onRight = Preferences.overlayOnRight
    var onAction: ((Action) -> Void)?

    init(shot: Shot, screen: NSScreen) {
        self.shot = shot
        screenFrame = screen.visibleFrame

        let size = CardLayout.size(width: Preferences.overlaySize.width, imageWidth: shot.image.width,
                                   imageHeight: shot.image.height)

        super.init(contentRect: NSRect(origin: .zero, size: size),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = .floating
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let view = CardView(frame: NSRect(origin: .zero, size: size), image: shot.image, isVideo: shot.video != nil)
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

    init(frame: NSRect, image: CGImage, isVideo: Bool = false) {
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

        let colors = NSImage.SymbolConfiguration(paletteColors: [NSColor.white, NSColor(white: 0, alpha: 0.45)])
        let badgeConfig = NSImage.SymbolConfiguration(pointSize: 28, weight: .regular).applying(colors)
        if isVideo, let symbol = NSImage(systemSymbolName: "play.circle.fill", accessibilityDescription: "収録")?
            .withSymbolConfiguration(badgeConfig) {
            let badge = NSImageView(image: symbol)
            badge.frame = NSRect(x: (bounds.width - 34) / 2, y: (bounds.height - 34) / 2, width: 34, height: 34)
            badge.autoresizingMask = [.minXMargin, .maxXMargin, .minYMargin, .maxYMargin]
            addSubview(badge)
        }

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

    /// Right click: every card action, plus the whole-stack ones, like CleanShot's overlay menu.
    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        let items: [(String, OverlayCard.Action)?] = [
            ("コピー", .copy), ("保存", .save), ("別名で保存…", .saveAs), nil,
            ("編集", .edit), ("ピン留め", .pin), nil,
            ("閉じる", .close), nil,
            ("すべて保存", .saveAll), ("すべて閉じる", .closeAll),
        ]
        for entry in items {
            guard let entry else {
                menu.addItem(.separator())
                continue
            }
            let (title, action) = entry
            menu.addItem(MenuAction(title: title) { [weak self] in self?.onAction?(action) })
        }
        return menu
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
