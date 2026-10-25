import AppKit

struct Annotation {
    enum Kind {
        case arrow(NSPoint, NSPoint)
        case rect(NSRect)
        case text(NSPoint, String)
        case number(NSPoint, Int)
        case mosaic(NSRect)
    }

    var kind: Kind
    var color: NSColor
}

enum Tool: Int, CaseIterable {
    case arrow, rect, text, number, mosaic

    var title: String { ["矢印", "四角", "文字", "番号", "モザイク"][rawValue] }
    /// Single-key shortcut inside the editor.
    var key: String { ["a", "r", "t", "n", "m"][rawValue] }
}

/// Draws a shot and its annotations in image point coordinates (bottom-left origin) into the
/// current NSGraphicsContext. Shared by the on-screen canvas and the export, so both look the same.
@MainActor
final class AnnotationRenderer {
    static let textFont = NSFont.systemFont(ofSize: 22, weight: .bold)

    let shot: Shot
    let size: NSSize
    private var pixelated: CGImage?

    init(shot: Shot) {
        self.shot = shot
        size = NSSize(width: CGFloat(shot.image.width) / shot.scale, height: CGFloat(shot.image.height) / shot.scale)
    }

    func draw(_ annotations: [Annotation]) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.interpolationQuality = .high
        context.draw(shot.image, in: NSRect(origin: .zero, size: size))
        annotations.forEach { draw($0, in: context) }
    }

    /// Bakes the annotations into a new image at the original resolution.
    func render(_ annotations: [Annotation]) -> Shot {
        guard !annotations.isEmpty else { return shot }
        let space = shot.image.colorSpace.flatMap { $0.supportsOutput ? $0 : nil }
            ?? CGColorSpace(name: CGColorSpace.sRGB)!
        guard let context = CGContext(
            data: nil, width: shot.image.width, height: shot.image.height, bitsPerComponent: 8, bytesPerRow: 0,
            space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return shot }
        context.scaleBy(x: shot.scale, y: shot.scale)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        draw(annotations)
        NSGraphicsContext.restoreGraphicsState()
        return context.makeImage().map { Shot(image: $0, scale: shot.scale) } ?? shot
    }

    private func draw(_ annotation: Annotation, in context: CGContext) {
        let color = annotation.color
        switch annotation.kind {
        case let .arrow(from, to):
            drawArrow(from: from, to: to, color: color)
        case let .rect(rect):
            color.setStroke()
            let path = NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4)
            path.lineWidth = 4
            path.stroke()
        case let .text(point, string):
            (string as NSString).draw(at: point, withAttributes: Self.textAttributes(color))
        case let .number(center, n):
            let radius: CGFloat = 14
            color.setFill()
            NSBezierPath(ovalIn: NSRect(x: center.x - radius, y: center.y - radius,
                                        width: radius * 2, height: radius * 2)).fill()
            let label = "\(n)" as NSString
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 16, weight: .bold),
                .foregroundColor: color.isLight ? NSColor.black : NSColor.white,
            ]
            let size = label.size(withAttributes: attributes)
            label.draw(at: NSPoint(x: center.x - size.width / 2, y: center.y - size.height / 2),
                       withAttributes: attributes)
        case let .mosaic(rect):
            guard let pixelated = pixelatedImage() else { return }
            context.saveGState()
            context.clip(to: rect)
            context.interpolationQuality = .none
            context.draw(pixelated, in: NSRect(origin: .zero, size: size))
            context.restoreGState()
        }
    }

    static func textAttributes(_ color: NSColor) -> [NSAttributedString.Key: Any] {
        [
            .font: textFont,
            .foregroundColor: color,
            .strokeColor: color.isLight ? NSColor.black : NSColor.white,
            .strokeWidth: -3, // negative: fill and outline
        ]
    }

    private func drawArrow(from: NSPoint, to: NSPoint, color: NSColor) {
        let length = hypot(to.x - from.x, to.y - from.y)
        guard length > 1 else { return }
        let angle = atan2(to.y - from.y, to.x - from.x)
        let head = min(20, length * 0.6)
        let spread: CGFloat = 0.45

        color.setStroke()
        let shaft = NSBezierPath()
        shaft.lineWidth = 4
        shaft.lineCapStyle = .round
        shaft.move(to: from)
        shaft.line(to: NSPoint(x: to.x - cos(angle) * head * 0.7, y: to.y - sin(angle) * head * 0.7))
        shaft.stroke()

        color.setFill()
        let tip = NSBezierPath()
        tip.move(to: to)
        tip.line(to: NSPoint(x: to.x - head * cos(angle - spread), y: to.y - head * sin(angle - spread)))
        tip.line(to: NSPoint(x: to.x - head * cos(angle + spread), y: to.y - head * sin(angle + spread)))
        tip.close()
        tip.fill()
    }

    /// The whole image shrunk to 12pt blocks; mosaic regions draw it back without interpolation.
    /// Built once on first use, so it costs nothing unless the mosaic tool is used.
    private func pixelatedImage() -> CGImage? {
        if let pixelated { return pixelated }
        let block = 12 * shot.scale
        let width = max(1, Int(CGFloat(shot.image.width) / block))
        let height = max(1, Int(CGFloat(shot.image.height) / block))
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }
        context.interpolationQuality = .medium
        context.draw(shot.image, in: CGRect(x: 0, y: 0, width: width, height: height))
        pixelated = context.makeImage()
        return pixelated
    }
}

private extension NSColor {
    var isLight: Bool {
        guard let rgb = usingColorSpace(.sRGB) else { return false }
        return 0.299 * rgb.redComponent + 0.587 * rgb.greenComponent + 0.114 * rgb.blueComponent > 0.7
    }
}

// MARK: - Window

@MainActor
final class EditorWindowController: NSWindowController, NSWindowDelegate {
    var onClose: (() -> Void)?

    private let canvas: CanvasView
    private let toolPicker: NSSegmentedControl
    private static let colors: [(String, NSColor)] = [
        ("赤", .systemRed), ("黄", .systemYellow), ("緑", .systemGreen),
        ("青", .systemBlue), ("白", .white), ("黒", .black),
    ]

    init(shot: Shot) {
        let canvas = CanvasView(renderer: AnnotationRenderer(shot: shot))
        let toolPicker = NSSegmentedControl(labels: Tool.allCases.map(\.title), trackingMode: .selectOne,
                                            target: nil, action: nil)
        self.canvas = canvas
        self.toolPicker = toolPicker

        let toolbarHeight: CGFloat = 44
        let visible = NSScreen.underMouse.visibleFrame
        let imageSize = canvas.renderer.size
        let fit = min(1, visible.width * 0.85 / imageSize.width,
                      (visible.height * 0.85 - toolbarHeight) / imageSize.height)
        let contentSize = NSSize(width: max(imageSize.width * fit + 32, 560),
                                 height: max(imageSize.height * fit + 32, 200) + toolbarHeight)

        let window = EditorWindow(contentRect: NSRect(origin: .zero, size: contentSize),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable],
                                  backing: .buffered, defer: false)
        window.title = "Karuta"
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 560, height: 240)
        super.init(window: window)
        window.delegate = self
        window.keyHandler = { [weak self] key in self?.handleCommand(key) ?? false }

        let content = NSView(frame: NSRect(origin: .zero, size: contentSize))
        canvas.frame = NSRect(x: 0, y: 0, width: contentSize.width, height: contentSize.height - toolbarHeight)
        canvas.autoresizingMask = [.width, .height]
        canvas.onToolChange = { [weak self] tool in self?.toolPicker.selectedSegment = tool.rawValue }
        content.addSubview(canvas)

        toolPicker.target = self
        toolPicker.action = #selector(toolChanged)
        toolPicker.selectedSegment = canvas.tool.rawValue

        let colorPicker = NSPopUpButton(frame: .zero, pullsDown: false)
        for (name, color) in Self.colors {
            colorPicker.addItem(withTitle: name)
            colorPicker.lastItem?.image = Self.swatch(color)
        }
        colorPicker.target = self
        colorPicker.action = #selector(colorChanged(_:))

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let toolbar = NSStackView(views: [
            toolPicker, colorPicker, spacer,
            NSButton(title: "取り消し", target: self, action: #selector(undo)),
            NSButton(title: "コピー", target: self, action: #selector(copyImage)),
            NSButton(title: "保存", target: self, action: #selector(saveImage)),
        ])
        toolbar.spacing = 8
        toolbar.edgeInsets = NSEdgeInsets(top: 0, left: 12, bottom: 0, right: 12)
        toolbar.frame = NSRect(x: 0, y: contentSize.height - toolbarHeight, width: contentSize.width, height: toolbarHeight)
        toolbar.autoresizingMask = [.width, .minYMargin]
        content.addSubview(toolbar)

        window.contentView = content
        window.center()
        window.makeFirstResponder(canvas)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func windowWillClose(_ notification: Notification) {
        onClose?()
    }

    private func handleCommand(_ key: String) -> Bool {
        if canvas.isEditingText {
            // Without an Edit menu, the text field's standard editing shortcuts need to be sent by hand.
            let actions: [String: Selector] = [
                "c": #selector(NSText.copy(_:)), "v": #selector(NSText.paste(_:)),
                "x": #selector(NSText.cut(_:)), "a": #selector(NSText.selectAll(_:)),
            ]
            guard let action = actions[key] else { return false }
            return NSApp.sendAction(action, to: nil, from: self)
        }
        switch key {
        case "c": copyImage()
        case "s": saveImage()
        case "z": undo()
        case "w": close()
        default: return false
        }
        return true
    }

    @objc private func toolChanged() {
        canvas.tool = Tool(rawValue: toolPicker.selectedSegment) ?? .arrow
        window?.makeFirstResponder(canvas)
    }

    @objc private func colorChanged(_ sender: NSPopUpButton) {
        canvas.color = Self.colors[sender.indexOfSelectedItem].1
        window?.makeFirstResponder(canvas)
    }

    @objc private func undo() {
        canvas.undo()
    }

    @objc private func copyImage() {
        Exporter.copy(canvas.renderedShot())
        close()
    }

    @objc private func saveImage() {
        do {
            try Exporter.save(canvas.renderedShot())
            close()
        } catch {
            let alert = NSAlert(error: error)
            alert.messageText = "保存できませんでした"
            if let window { alert.beginSheetModal(for: window) }
        }
    }

    private static func swatch(_ color: NSColor) -> NSImage {
        NSImage(size: NSSize(width: 12, height: 12), flipped: false) { rect in
            color.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 0.5, dy: 0.5)).fill()
            NSColor.separatorColor.setStroke()
            NSBezierPath(ovalIn: rect.insetBy(dx: 0.5, dy: 0.5)).stroke()
            return true
        }
    }
}

/// The app has no main menu, so ⌘-shortcuts are routed here.
private final class EditorWindow: NSWindow {
    var keyHandler: ((String) -> Bool)?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
           let key = event.charactersIgnoringModifiers?.lowercased(),
           keyHandler?(key) == true {
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

// MARK: - Canvas

private final class CanvasView: NSView, NSTextFieldDelegate {
    let renderer: AnnotationRenderer
    var tool: Tool = .arrow
    var color: NSColor = .systemRed
    var onToolChange: ((Tool) -> Void)?

    private var annotations: [Annotation] = [] { didSet { needsDisplay = true } }
    private var preview: Annotation? { didSet { needsDisplay = true } }
    private var dragStart: NSPoint?
    private var textField: NSTextField?
    private var textOrigin: NSPoint = .zero

    var isEditingText: Bool { textField != nil }

    init(renderer: AnnotationRenderer) {
        self.renderer = renderer
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }

    func undo() {
        _ = annotations.popLast()
    }

    func renderedShot() -> Shot {
        commitText()
        return renderer.render(annotations)
    }

    // MARK: Geometry

    /// Where the image sits in the view, scaled to fit (never enlarged).
    private var imageRect: NSRect {
        let area = bounds.insetBy(dx: 16, dy: 16)
        let size = renderer.size
        let zoom = min(1, area.width / size.width, area.height / size.height)
        let fitted = NSSize(width: size.width * zoom, height: size.height * zoom)
        return NSRect(x: bounds.midX - fitted.width / 2, y: bounds.midY - fitted.height / 2,
                      width: fitted.width, height: fitted.height)
    }

    private var zoom: CGFloat { imageRect.width / renderer.size.width }

    private func imagePoint(for event: NSEvent) -> NSPoint {
        let p = convert(event.locationInWindow, from: nil)
        let rect = imageRect
        return NSPoint(x: (min(max(p.x, rect.minX), rect.maxX) - rect.minX) / zoom,
                       y: (min(max(p.y, rect.minY), rect.maxY) - rect.minY) / zoom)
    }

    private func viewPoint(_ p: NSPoint) -> NSPoint {
        NSPoint(x: imageRect.minX + p.x * zoom, y: imageRect.minY + p.y * zoom)
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        NSColor.underPageBackgroundColor.setFill()
        bounds.fill()
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let rect = imageRect
        context.saveGState()
        context.translateBy(x: rect.minX, y: rect.minY)
        context.scaleBy(x: zoom, y: zoom)
        context.clip(to: NSRect(origin: .zero, size: renderer.size))
        renderer.draw(annotations + (preview.map { [$0] } ?? []))
        context.restoreGState()
    }

    override func setFrameSize(_ newSize: NSSize) {
        commitText()
        super.setFrameSize(newSize)
    }

    // MARK: Input

    override func mouseDown(with event: NSEvent) {
        commitText()
        let p = imagePoint(for: event)
        switch tool {
        case .text:
            beginText(at: p)
        case .number:
            let next = annotations.filter { if case .number = $0.kind { true } else { false } }.count + 1
            annotations.append(Annotation(kind: .number(p, next), color: color))
        case .arrow, .rect, .mosaic:
            dragStart = p
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = dragStart else { return }
        let p = imagePoint(for: event)
        let rect = NSRect(x: min(start.x, p.x), y: min(start.y, p.y),
                          width: abs(start.x - p.x), height: abs(start.y - p.y))
        switch tool {
        case .arrow: preview = Annotation(kind: .arrow(start, p), color: color)
        case .rect: preview = Annotation(kind: .rect(rect), color: color)
        case .mosaic: preview = Annotation(kind: .mosaic(rect), color: color)
        case .text, .number: break
        }
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            dragStart = nil
            preview = nil
        }
        guard let preview else { return }
        switch preview.kind {
        case let .arrow(a, b) where hypot(b.x - a.x, b.y - a.y) < 4: return
        case let .rect(r) where r.width < 4 || r.height < 4: return
        case let .mosaic(r) where r.width < 4 || r.height < 4: return
        default: annotations.append(preview)
        }
    }

    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if modifiers.isEmpty, let key = event.charactersIgnoringModifiers?.lowercased(),
           let tool = Tool.allCases.first(where: { $0.key == key }) {
            self.tool = tool
            onToolChange?(tool)
        } else if event.keyCode == 51 { // Delete
            undo()
        } else {
            super.keyDown(with: event)
        }
    }

    // MARK: Text

    private func beginText(at point: NSPoint) {
        textOrigin = point
        let font = NSFont.systemFont(ofSize: AnnotationRenderer.textFont.pointSize * zoom, weight: .bold)
        let field = NSTextField(frame: NSRect(origin: viewPoint(point),
                                              size: NSSize(width: 240, height: font.boundingRectForFont.height)))
        field.font = font
        field.textColor = color
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.placeholderString = "テキスト"
        field.delegate = self
        field.target = self
        field.action = #selector(textCommitted)
        addSubview(field)
        window?.makeFirstResponder(field)
        textField = field
    }

    @objc private func textCommitted() {
        commitText()
        window?.makeFirstResponder(self)
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        commitText()
    }

    private func commitText() {
        guard let field = textField else { return }
        textField = nil
        let string = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        field.removeFromSuperview()
        if !string.isEmpty {
            annotations.append(Annotation(kind: .text(textOrigin, string), color: color))
        }
    }
}
