import AppKit
@preconcurrency import ScreenCaptureKit

/// Full-screen overlay (one window per display) for picking an area or a window.
@MainActor
final class SelectionController {
    enum Result {
        case area(CGRect, NSScreen) // AppKit global coordinates
        case window(SCWindow)
        case cancelled
    }

    private(set) var windowMode = false
    private(set) var hovered: SCWindow? {
        didSet {
            if hovered?.windowID != oldValue?.windowID { redrawAll() }
        }
    }

    private var candidates: [SCWindow] = []
    private var windows: [SelectionWindow] = []
    private var previousApp: NSRunningApplication?
    private var continuation: CheckedContinuation<Result, Never>?

    func run(windowMode: Bool, candidates: [SCWindow]) async -> Result {
        self.windowMode = windowMode
        self.candidates = candidates
        previousApp = NSWorkspace.shared.frontmostApplication

        windows = NSScreen.screens.map { SelectionWindow(screen: $0, controller: self) }
        windows.forEach { $0.orderFrontRegardless() }
        NSApp.activate()
        let mouse = NSEvent.mouseLocation
        (windows.first { $0.frame.contains(mouse) } ?? windows.first)?.makeKey()
        updateHover(at: mouse)

        return await withCheckedContinuation { continuation = $0 }
    }

    func toggleMode() {
        windowMode.toggle()
        updateHover(at: NSEvent.mouseLocation)
        redrawAll()
    }

    func updateHover(at point: NSPoint) {
        guard windowMode else {
            hovered = nil
            return
        }
        hovered = candidates.first { Geometry.appKitRect(fromCG: $0.frame).contains(point) }
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
        windows.forEach { $0.contentView?.needsDisplay = true }
    }
}

private final class SelectionWindow: NSWindow {
    init(screen: NSScreen, controller: SelectionController) {
        super.init(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        setFrame(screen.frame, display: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        isReleasedWhenClosed = false
        acceptsMouseMovedEvents = true
        let view = SelectionView(screen: screen, controller: controller)
        contentView = view
        makeFirstResponder(view)
    }

    override var canBecomeKey: Bool { true }
}

private final class SelectionView: NSView {
    private unowned let controller: SelectionController
    private let screen: NSScreen
    private var start: NSPoint?
    private var current: NSPoint?

    init(screen: NSScreen, controller: SelectionController) {
        self.screen = screen
        self.controller = controller
        super.init(frame: NSRect(origin: .zero, size: screen.frame.size))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private var selection: NSRect? {
        guard let start, let current else { return nil }
        return NSRect(
            x: min(start.x, current.x), y: min(start.y, current.y),
            width: abs(start.x - current.x), height: abs(start.y - current.y)
        )
    }

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

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }

    override func mouseEntered(with event: NSEvent) {
        window?.makeKey()
        NSCursor.crosshair.set()
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        needsDisplay = true
    }

    override func mouseMoved(with event: NSEvent) {
        NSCursor.crosshair.set()
        controller.updateHover(at: NSEvent.mouseLocation)
    }

    override func mouseDown(with event: NSEvent) {
        start = clamped(convert(event.locationInWindow, from: nil))
        current = start
    }

    override func mouseDragged(with event: NSEvent) {
        current = clamped(convert(event.locationInWindow, from: nil))
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        if let rect = selection, rect.width >= 4, rect.height >= 4 {
            let global = rect.offsetBy(dx: screen.frame.minX, dy: screen.frame.minY)
            controller.finish(.area(global, screen))
        } else if controller.windowMode, let window = controller.hovered {
            controller.finish(.window(window))
        } else {
            start = nil
            current = nil
            needsDisplay = true
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        controller.finish(.cancelled)
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53: controller.finish(.cancelled) // Esc
        case 49 where selection == nil: controller.toggleMode() // Space
        default: super.keyDown(with: event)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.2).setFill()
        bounds.fill()

        if let rect = selection {
            rect.fill(using: .clear)
            NSColor.white.setStroke()
            let path = NSBezierPath(rect: rect.insetBy(dx: 0.5, dy: 0.5))
            path.lineWidth = 1
            path.stroke()
            drawSizeLabel(for: rect)
        } else if controller.windowMode, let window = controller.hovered {
            let rect = Geometry.appKitRect(fromCG: window.frame)
                .offsetBy(dx: -screen.frame.minX, dy: -screen.frame.minY)
            rect.fill(using: .clear)
            NSColor.controlAccentColor.withAlphaComponent(0.25).setFill()
            rect.fill(using: .sourceOver)
        } else {
            drawHint()
        }
    }

    private func clamped(_ point: NSPoint) -> NSPoint {
        NSPoint(x: min(max(point.x, 0), bounds.maxX), y: min(max(point.y, 0), bounds.maxY))
    }

    private static let labelAttributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium),
        .foregroundColor: NSColor.white,
    ]

    private func drawSizeLabel(for rect: NSRect) {
        let scale = screen.backingScaleFactor
        let text = "\(Int((rect.width * scale).rounded())) × \(Int((rect.height * scale).rounded()))" as NSString
        let size = text.size(withAttributes: Self.labelAttributes)
        var box = NSRect(x: rect.maxX - size.width - 12, y: rect.minY - size.height - 12,
                         width: size.width + 12, height: size.height + 6)
        if box.minY < 4 { box.origin.y = rect.minY + 4 }
        if box.minX < 4 { box.origin.x = rect.minX + 4 }
        drawLabel(text, in: box)
    }

    private func drawHint() {
        guard screen.displayID == NSScreen.underMouse.displayID else { return }
        let text = (controller.windowMode
            ? "クリックでウィンドウを撮影 ・ Space: 範囲選択 ・ Esc: キャンセル"
            : "ドラッグで範囲を選択 ・ Space: ウィンドウ ・ Esc: キャンセル") as NSString
        let size = text.size(withAttributes: Self.labelAttributes)
        let box = NSRect(x: (bounds.width - size.width) / 2 - 8, y: bounds.maxY - size.height - 60,
                         width: size.width + 16, height: size.height + 8)
        drawLabel(text, in: box)
    }

    private func drawLabel(_ text: NSString, in box: NSRect) {
        NSColor.black.withAlphaComponent(0.75).setFill()
        NSBezierPath(roundedRect: box, xRadius: 4, yRadius: 4).fill()
        let size = text.size(withAttributes: Self.labelAttributes)
        text.draw(at: NSPoint(x: box.midX - size.width / 2, y: box.midY - size.height / 2),
                  withAttributes: Self.labelAttributes)
    }
}
