import AppKit
@preconcurrency import ScreenCaptureKit

/// Full-screen overlay (one window per display) for picking an area or a window, CleanShot style:
/// the screen is frozen, a crosshair guide and a magnifier follow the cursor, and modifiers shape the selection.
///
/// - Drag: select an area. Shift = square, Option = from the center, hold Space = move the selection.
/// - Arrow keys: move the cursor by 1pt (Shift: 10pt), also while dragging.
/// - Space (not dragging): switch between area and window selection. Click / Return: capture the window.
/// - Esc / right click: cancel.
@MainActor
final class SelectionController {
    enum Result {
        case area(CGRect, NSScreen) // AppKit global coordinates
        case window(SCWindow)
        case cancelled
    }

    private(set) var windowMode = false
    private(set) var hovered: SCWindow?
    /// The cursor position in AppKit global coordinates.
    private(set) var mouse = NSPoint.zero

    private var candidates: [SCWindow] = []
    private var windows: [SelectionWindow] = []
    private var previousApp: NSRunningApplication?
    private var continuation: CheckedContinuation<Result, Never>?

    /// `frozen` holds a full capture of each display (keyed by display ID) to show instead of the live screen.
    func run(windowMode: Bool, candidates: [SCWindow], frozen: [CGDirectDisplayID: Shot]) async -> Result {
        self.windowMode = windowMode
        self.candidates = candidates
        previousApp = NSWorkspace.shared.frontmostApplication

        windows = NSScreen.screens.map { screen in
            SelectionWindow(screen: screen, frozen: screen.displayID.flatMap { frozen[$0] }, controller: self)
        }
        windows.forEach { $0.orderFrontRegardless() }
        NSApp.activate()
        mouse = NSEvent.mouseLocation
        (windows.first { $0.frame.contains(mouse) } ?? windows.first)?.makeKey()
        updateHover()
        redrawAll()

        return await withCheckedContinuation { continuation = $0 }
    }

    func toggleMode() {
        windowMode.toggle()
        updateHover()
        windows.forEach { $0.selectionView.modeChanged() }
        redrawAll()
    }

    func mouseMoved(to point: NSPoint) {
        mouse = point
        updateHover()
        redrawAll()
    }

    private func updateHover() {
        hovered = windowMode ? candidates.first { Geometry.appKitRect(fromCG: $0.frame).contains(mouse) } : nil
    }

    func finish(_ result: Result) {
        windows.forEach { $0.orderOut(nil) }
        windows.removeAll()
        candidates.removeAll()
        hovered = nil
        if let previousApp, previousApp != NSRunningApplication.current {
            previousApp.activate()
        }
        previousApp = nil
        continuation?.resume(returning: result)
        continuation = nil
    }

    private func redrawAll() {
        windows.forEach { $0.selectionView.needsDisplay = true }
    }
}

private final class SelectionWindow: NSWindow {
    let selectionView: SelectionView

    init(screen: NSScreen, frozen: Shot?, controller: SelectionController) {
        let size = screen.frame.size
        selectionView = SelectionView(screen: screen, frozen: frozen, controller: controller)
        super.init(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        setFrame(screen.frame, display: false)
        isOpaque = frozen != nil
        backgroundColor = .clear
        hasShadow = false
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        isReleasedWhenClosed = false
        acceptsMouseMovedEvents = true

        // The frozen screen is a layer underneath; the selection is drawn on a transparent view on top.
        let container = NSView(frame: NSRect(origin: .zero, size: size))
        container.wantsLayer = true
        if let frozen {
            let background = NSView(frame: container.bounds)
            background.wantsLayer = true
            background.layer?.contents = frozen.image
            background.layer?.contentsGravity = .resize
            background.autoresizingMask = [.width, .height]
            container.addSubview(background)
        }
        selectionView.frame = container.bounds
        selectionView.autoresizingMask = [.width, .height]
        container.addSubview(selectionView)
        contentView = container
        makeFirstResponder(selectionView)
    }

    override var canBecomeKey: Bool { true }
}

private final class SelectionView: NSView {
    private unowned let controller: SelectionController
    private let screen: NSScreen
    private let frozen: Shot?

    private var anchor: NSPoint?
    private var current: NSPoint?
    private var lastDrag: NSPoint?
    private var spaceHeld = false
    private var modifiers: NSEvent.ModifierFlags = []

    init(screen: NSScreen, frozen: Shot?, controller: SelectionController) {
        self.screen = screen
        self.frozen = frozen
        self.controller = controller
        super.init(frame: NSRect(origin: .zero, size: screen.frame.size))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private var isDragging: Bool { anchor != nil }

    /// The selection in view coordinates, shaped by Shift (square) and Option (from center), snapped to points.
    private var selection: NSRect? {
        guard let anchor, let current else { return nil }
        var dx = current.x - anchor.x
        var dy = current.y - anchor.y
        if modifiers.contains(.shift) {
            let side = max(abs(dx), abs(dy))
            dx = dx < 0 ? -side : side
            dy = dy < 0 ? -side : side
        }
        let rect = modifiers.contains(.option)
            ? NSRect(x: anchor.x - abs(dx), y: anchor.y - abs(dy), width: abs(dx) * 2, height: abs(dy) * 2)
            : NSRect(x: min(anchor.x, anchor.x + dx), y: min(anchor.y, anchor.y + dy), width: abs(dx), height: abs(dy))
        let clipped = rect.intersection(bounds)
        guard !clipped.isNull else { return nil }
        let minX = clipped.minX.rounded(), minY = clipped.minY.rounded()
        return NSRect(x: minX, y: minY, width: clipped.maxX.rounded() - minX, height: clipped.maxY.rounded() - minY)
    }

    /// The cursor in view coordinates, if it is on this screen.
    private var localMouse: NSPoint? {
        let mouse = controller.mouse
        guard NSMouseInRect(mouse, screen.frame, false) else { return nil }
        return NSPoint(x: mouse.x - screen.frame.minX, y: mouse.y - screen.frame.minY)
    }

    // MARK: - Cursor

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self
        ))
    }

    /// Like ⌘⇧4 in macOS: crosshair for areas, camera for windows.
    private var currentCursor: NSCursor {
        controller.windowMode ? Self.cameraCursor : .crosshair
    }

    private static let cameraCursor: NSCursor = {
        let config = NSImage.SymbolConfiguration(pointSize: 20, weight: .regular)
        guard let image = NSImage(systemSymbolName: "camera.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(config)
        else { return .crosshair }
        return NSCursor(image: image, hotSpot: NSPoint(x: image.size.width / 2, y: image.size.height / 2))
    }()

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: currentCursor)
    }

    func modeChanged() {
        window?.invalidateCursorRects(for: self)
        if window?.isKeyWindow == true { currentCursor.set() }
    }

    // MARK: - Mouse

    override func mouseEntered(with event: NSEvent) {
        window?.makeKey()
        currentCursor.set()
        controller.mouseMoved(to: NSEvent.mouseLocation)
    }

    override func mouseExited(with event: NSEvent) {
        needsDisplay = true
    }

    override func mouseMoved(with event: NSEvent) {
        currentCursor.set()
        modifiers = event.modifierFlags
        controller.mouseMoved(to: NSEvent.mouseLocation)
    }

    override func mouseDown(with event: NSEvent) {
        let point = clamped(convert(event.locationInWindow, from: nil))
        modifiers = event.modifierFlags
        anchor = point
        current = point
        lastDrag = point
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        let point = clamped(convert(event.locationInWindow, from: nil))
        modifiers = event.modifierFlags
        dragTo(point)
        controller.mouseMoved(to: NSEvent.mouseLocation)
    }

    private func dragTo(_ point: NSPoint) {
        if spaceHeld, let anchor, let lastDrag {
            // Space held: move the whole selection instead of resizing it.
            self.anchor = NSPoint(x: anchor.x + point.x - lastDrag.x, y: anchor.y + point.y - lastDrag.y)
        }
        current = point
        lastDrag = point
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        let rect = selection
        anchor = nil
        current = nil
        lastDrag = nil
        if let rect, rect.width >= 4, rect.height >= 4 {
            let global = rect.offsetBy(dx: screen.frame.minX, dy: screen.frame.minY)
            controller.finish(.area(global, screen))
        } else if controller.windowMode, let window = controller.hovered {
            controller.finish(.window(window))
        } else {
            needsDisplay = true
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        controller.finish(.cancelled)
    }

    // MARK: - Keyboard

    override func flagsChanged(with event: NSEvent) {
        modifiers = event.modifierFlags
        needsDisplay = true
    }

    override func keyDown(with event: NSEvent) {
        modifiers = event.modifierFlags
        switch event.keyCode {
        case 53: // Esc
            controller.finish(.cancelled)
        case 49: // Space
            if isDragging {
                spaceHeld = true
            } else if !event.isARepeat {
                controller.toggleMode()
            }
        case 36, 76: // Return / Enter
            if controller.windowMode, let window = controller.hovered {
                controller.finish(.window(window))
            }
        case 123, 124, 125, 126: // ← → ↓ ↑
            nudge(keyCode: event.keyCode, step: event.modifierFlags.contains(.shift) ? 10 : 1)
        default:
            super.keyDown(with: event)
        }
    }

    override func keyUp(with event: NSEvent) {
        if event.keyCode == 49 { spaceHeld = false } else { super.keyUp(with: event) }
    }

    /// Moves the cursor (and the dragged edge) for pixel-precise selections.
    private func nudge(keyCode: UInt16, step: CGFloat) {
        var mouse = controller.mouse
        switch keyCode {
        case 123: mouse.x -= step
        case 124: mouse.x += step
        case 125: mouse.y -= step
        default: mouse.y += step
        }
        let frame = screen.frame
        mouse.x = min(max(mouse.x, frame.minX), frame.maxX - 1)
        mouse.y = min(max(mouse.y, frame.minY), frame.maxY - 1)

        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        CGWarpMouseCursorPosition(CGPoint(x: mouse.x, y: primaryHeight - mouse.y))
        CGAssociateMouseAndMouseCursorPosition(1)
        if isDragging {
            // Shift is the nudge step here, not "square".
            modifiers.remove(.shift)
            dragTo(NSPoint(x: mouse.x - frame.minX, y: mouse.y - frame.minY))
        }
        controller.mouseMoved(to: mouse)
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        if let rect = selection {
            NSColor.black.withAlphaComponent(0.35).setFill()
            bounds.fill()
            rect.fill(using: .clear)
            NSColor.white.setStroke()
            let path = NSBezierPath(rect: rect.insetBy(dx: 0.5, dy: 0.5))
            path.lineWidth = 1
            path.stroke()
        } else if controller.windowMode, let window = controller.hovered {
            let rect = Geometry.appKitRect(fromCG: window.frame)
                .offsetBy(dx: -screen.frame.minX, dy: -screen.frame.minY)
            NSColor.controlAccentColor.withAlphaComponent(0.25).setFill()
            rect.fill(using: .sourceOver)
        }

        guard let mouse = localMouse else { return }
        if controller.windowMode {
            if let window = controller.hovered {
                let size = window.frame.size
                drawPill("\(Int(size.width)) × \(Int(size.height))", near: mouse)
            }
            return
        }
        if !isDragging { drawGuides(at: mouse) }
        drawLoupe(at: mouse)
        if let rect = selection {
            drawPill("\(Int(rect.width)) × \(Int(rect.height))", near: mouse)
        }
    }

    private func clamped(_ point: NSPoint) -> NSPoint {
        NSPoint(x: min(max(point.x, 0), bounds.maxX), y: min(max(point.y, 0), bounds.maxY))
    }

    /// Full-width and full-height lines through the cursor.
    private func drawGuides(at point: NSPoint) {
        let x = point.x.rounded(.down) + 0.5
        let y = point.y.rounded(.down) + 0.5
        let path = NSBezierPath()
        path.move(to: NSPoint(x: 0, y: y))
        path.line(to: NSPoint(x: bounds.maxX, y: y))
        path.move(to: NSPoint(x: x, y: 0))
        path.line(to: NSPoint(x: x, y: bounds.maxY))
        path.lineWidth = 1
        NSColor.black.withAlphaComponent(0.35).setStroke()
        path.stroke()
        path.setLineDash([4, 4], count: 2, phase: 0)
        NSColor.white.withAlphaComponent(0.9).setStroke()
        path.stroke()
    }

    private static let loupeCells = 15
    private static let loupeCellSize: CGFloat = 8

    /// A pixel magnifier with the cursor's coordinates, placed below-right of the cursor (flipped near edges).
    private func drawLoupe(at point: NSPoint) {
        guard let frozen, let context = NSGraphicsContext.current?.cgContext else { return }
        let cells = Self.loupeCells
        let side = CGFloat(cells) * Self.loupeCellSize
        let coordinates = "\(Int(point.x)), \(Int(bounds.height - point.y))" as NSString
        let labelSize = coordinates.size(withAttributes: Self.labelAttributes)
        let labelHeight = labelSize.height + 6
        let offset: CGFloat = 24

        var origin = NSPoint(x: point.x + offset, y: point.y - offset - side - labelHeight - 4)
        if origin.x + side > bounds.maxX - 4 { origin.x = point.x - offset - side }
        if origin.y < 4 { origin.y = point.y + offset }
        let loupe = NSRect(x: origin.x, y: origin.y + labelHeight + 4, width: side, height: side)

        // Source pixels (top-left origin) centered on the cursor.
        let scale = frozen.scale
        let center = CGPoint(x: (point.x * scale).rounded(.down), y: ((bounds.height - point.y) * scale).rounded(.down))
        let half = CGFloat(cells / 2)
        let source = CGRect(x: center.x - half, y: center.y - half, width: CGFloat(cells), height: CGFloat(cells))
        let imageBounds = CGRect(x: 0, y: 0, width: frozen.image.width, height: frozen.image.height)
        let clip = source.intersection(imageBounds)

        let rounded = NSBezierPath(roundedRect: loupe, xRadius: 10, yRadius: 10)
        NSGraphicsContext.saveGraphicsState()
        rounded.addClip()
        NSColor.black.setFill()
        loupe.fill()
        if !clip.isNull, let pixels = frozen.image.cropping(to: clip) {
            let cell = Self.loupeCellSize
            let dest = CGRect(
                x: loupe.minX + (clip.minX - source.minX) * cell,
                y: loupe.maxY - (clip.maxY - source.minY) * cell,
                width: clip.width * cell, height: clip.height * cell
            )
            context.interpolationQuality = .none
            context.draw(pixels, in: dest)
        }
        // Outline the center pixel.
        let cell = Self.loupeCellSize
        let centerCell = NSRect(x: loupe.minX + half * cell, y: loupe.maxY - (half + 1) * cell, width: cell, height: cell)
        NSColor.black.withAlphaComponent(0.6).setStroke()
        NSBezierPath(rect: centerCell.insetBy(dx: -0.5, dy: -0.5)).stroke()
        NSColor.white.setStroke()
        NSBezierPath(rect: centerCell.insetBy(dx: 0.5, dy: 0.5)).stroke()
        NSGraphicsContext.restoreGraphicsState()

        NSColor.white.withAlphaComponent(0.9).setStroke()
        rounded.lineWidth = 2
        rounded.stroke()

        let label = NSRect(x: loupe.midX - (labelSize.width + 12) / 2, y: origin.y,
                           width: labelSize.width + 12, height: labelHeight)
        drawLabel(coordinates, in: label)
    }

    private static let labelAttributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium),
        .foregroundColor: NSColor.white,
    ]

    /// A small dark label just above-right of the cursor.
    private func drawPill(_ string: String, near point: NSPoint) {
        let text = string as NSString
        let size = text.size(withAttributes: Self.labelAttributes)
        var box = NSRect(x: point.x + 14, y: point.y + 14, width: size.width + 12, height: size.height + 6)
        if box.maxX > bounds.maxX - 4 { box.origin.x = point.x - 14 - box.width }
        if box.maxY > bounds.maxY - 4 { box.origin.y = point.y - 14 - box.height }
        drawLabel(text, in: box)
    }

    private func drawLabel(_ text: NSString, in box: NSRect) {
        NSColor.black.withAlphaComponent(0.75).setFill()
        NSBezierPath(roundedRect: box, xRadius: box.height / 2, yRadius: box.height / 2).fill()
        let size = text.size(withAttributes: Self.labelAttributes)
        text.draw(at: NSPoint(x: box.midX - size.width / 2, y: box.midY - size.height / 2),
                  withAttributes: Self.labelAttributes)
    }
}
