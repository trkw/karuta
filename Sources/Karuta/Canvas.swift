import AppKit

enum Tool: CaseIterable {
    case select, crop, rect, filledRect, ellipse, line, arrow, text, pixelate, blur, spotlight, counter, pen, highlighter

    var title: String {
        switch self {
        case .select: "選択"
        case .crop: "切り抜き"
        case .rect: "四角"
        case .filledRect: "塗りつぶし四角"
        case .ellipse: "楕円"
        case .line: "線"
        case .arrow: "矢印"
        case .text: "文字"
        case .pixelate: "モザイク"
        case .blur: "ぼかし"
        case .spotlight: "スポットライト"
        case .counter: "番号"
        case .pen: "ペン"
        case .highlighter: "蛍光ペン"
        }
    }

    var symbol: String {
        switch self {
        case .select: "cursorarrow"
        case .crop: "crop"
        case .rect: "square"
        case .filledRect: "square.fill"
        case .ellipse: "circle"
        case .line: "line.diagonal"
        case .arrow: "arrow.down.left"
        case .text: "textformat"
        case .pixelate: "checkerboard.rectangle"
        case .blur: "drop.fill"
        case .spotlight: "rectangle.inset.filled"
        case .counter: "1.circle.fill"
        case .pen: "pencil.tip"
        case .highlighter: "highlighter"
        }
    }

    /// Tools with a choice of looks (`Annotation.style`), by the name the choice is remembered under.
    var styleKey: String? {
        switch self {
        case .arrow: "arrow"
        case .text: "text"
        case .pixelate: "pixelate"
        case .counter: "counter"
        default: nil
        }
    }

    /// Single-key shortcut, following CleanShot where it has one.
    var key: String {
        switch self {
        case .select: "v"
        case .crop: "c"
        case .rect: "r"
        case .filledRect: "f"
        case .ellipse: "e"
        case .line: "l"
        case .arrow: "a"
        case .text: "t"
        case .pixelate: "p"
        case .blur: "u"
        case .spotlight: "h"
        case .counter: "s"
        case .pen: "d"
        case .highlighter: "m"
        }
    }
}

/// The editing surface: shows the shot (optionally cropped and on a backdrop) at a zoom, and turns mouse
/// input into annotations. Coordinates in annotations are image points with a bottom-left origin.
final class CanvasView: NSView, NSTextFieldDelegate {
    /// Replaced when the picture itself is rotated or flipped.
    private(set) var renderer: AnnotationRenderer

    var tool: Tool = .arrow {
        didSet {
            guard tool != oldValue else { return }
            commitText()
            selected = nil
            updateFrame()
            onStateChange?()
        }
    }
    var color: NSColor = .systemRed {
        didSet { restyleSelection { $0.color = color } }
    }
    var lineWidth: CGFloat = 4 {
        didSet { restyleSelection { $0.width = lineWidth } }
    }
    var background = false {
        didSet {
            updateFrame()
            onStateChange?()
        }
    }
    /// nil fits the image to the window.
    var zoomLevel: CGFloat? {
        didSet { updateFrame() }
    }
    var onStateChange: (() -> Void)?

    var annotations: [Annotation] = [] { didSet { needsDisplay = true } }
    /// Undo keeps the picture too, so rotating and flipping can be undone.
    private struct Snapshot {
        var annotations: [Annotation]
        var renderer: AnnotationRenderer
        var crop: NSRect?
    }

    private var undoStack: [Snapshot] = []
    private var redoStack: [Snapshot] = []
    /// The next counter's number when typed in; otherwise it follows the highest one on the picture.
    var counterOverride: Int?
    var preview: Annotation? { didSet { needsDisplay = true } }
    var crop: NSRect? { didSet { needsDisplay = true } }
    var selected: Int? {
        didSet {
            needsDisplay = true
            if selected != oldValue { onStateChange?() } // the toolbar shows the selected mark's look
        }
    }

    var dragStart: NSPoint?
    var lastDrag: NSPoint?
    var textField: NSTextField?
    var textOrigin: NSPoint = .zero

    var isEditingText: Bool { textField != nil }
    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    init(renderer: AnnotationRenderer) {
        self.renderer = renderer
        super.init(frame: .zero)
        NotificationCenter.default.addObserver(self, selector: #selector(preferencesChanged),
                                               name: Preferences.didChange, object: nil)
    }

    /// The backdrop's style and padding live in Preferences.
    @objc private func preferencesChanged() {
        guard background else { return }
        updateFrame()
        needsDisplay = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }

    // MARK: History

    private var snapshot: Snapshot { Snapshot(annotations: annotations, renderer: renderer, crop: crop) }

    func commit(_ new: [Annotation]) {
        undoStack.append(snapshot)
        redoStack.removeAll()
        annotations = new
        onStateChange?()
    }

    private func restore(_ state: Snapshot) {
        annotations = state.annotations
        // The crop isn't part of undo on its own; it only comes back with the picture it was made on.
        if state.renderer !== renderer {
            renderer = state.renderer
            crop = state.crop
            updateFrame()
        }
        selected = nil
        onStateChange?()
    }

    func undo() {
        commitText()
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(snapshot)
        restore(previous)
    }

    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(snapshot)
        restore(next)
    }

    // MARK: Looks

    func style(for tool: Tool) -> Int {
        tool.styleKey.map(Preferences.editorStyle) ?? 0
    }

    /// Remembers the look for the tool, and restyles the selected mark if it was made with that tool.
    func setStyle(_ style: Int, for tool: Tool) {
        guard let key = tool.styleKey else { return }
        Preferences.setEditorStyle(style, for: key)
        if let index = selected, annotations.indices.contains(index), Self.tool(for: annotations[index]) == tool {
            restyleSelection { $0.style = style }
        } else {
            onStateChange?()
        }
    }

    /// The tool whose looks the toolbar offers: the current one, or with Select, the selected mark's.
    var styleTarget: Tool? {
        if tool != .select { return tool.styleKey == nil ? nil : tool }
        guard let index = selected, annotations.indices.contains(index) else { return nil }
        return Self.tool(for: annotations[index])
    }

    private static func tool(for annotation: Annotation) -> Tool? {
        switch annotation.kind {
        case .arrow: .arrow
        case .text: .text
        case .pixelate: .pixelate
        case .counter: .counter
        default: nil
        }
    }

    var nextCounter: Int {
        get {
            if let counterOverride { return counterOverride }
            var highest = 0
            for annotation in annotations {
                if case let .counter(_, n) = annotation.kind { highest = max(highest, n) }
            }
            return highest + 1
        }
        set { counterOverride = max(0, newValue) }
    }

    /// The look the toolbar shows: the selected mark's own, else the one new marks get.
    var shownStyle: Int {
        if tool == .select, let index = selected, annotations.indices.contains(index) { return annotations[index].style }
        return styleTarget.map(style(for:)) ?? 0
    }

    /// A new mark in the current color, width and look. `tool` is the tool that made it, when that may
    /// no longer be the current one (text is committed after switching tools).
    func mark(_ kind: Annotation.Kind, by tool: Tool? = nil) -> Annotation {
        Annotation(kind: kind, color: color, width: lineWidth, style: style(for: tool ?? self.tool))
    }

    // MARK: Edits

    /// ⌘D: a copy of the selected mark, a little down and to the right.
    func duplicateSelection() -> Bool {
        guard let index = selected, annotations.indices.contains(index) else { return false }
        var list = annotations
        list.append(list[index].offsetBy(dx: 12, dy: -12))
        selected = list.count - 1
        commit(list)
        return true
    }

    enum Transform { case rotateLeft, rotateRight, flipHorizontal, flipVertical }

    /// Rotates or flips the picture. The marks and crop are baked in first, so they turn with it.
    func apply(_ transform: Transform) {
        commitText()
        let shot = renderer.render(annotations, crop: crop)
        let w = CGFloat(shot.image.width), h = CGFloat(shot.image.height)
        let rotates = transform == .rotateLeft || transform == .rotateRight
        guard let context = AnnotationRenderer.bitmap(width: Int(rotates ? h : w), height: Int(rotates ? w : h),
                                                      space: shot.image.colorSpace)
        else { return }
        switch transform {
        case .rotateLeft:
            context.translateBy(x: h, y: 0)
            context.rotate(by: .pi / 2)
        case .rotateRight:
            context.translateBy(x: 0, y: w)
            context.rotate(by: -.pi / 2)
        case .flipHorizontal:
            context.translateBy(x: w, y: 0)
            context.scaleBy(x: -1, y: 1)
        case .flipVertical:
            context.translateBy(x: 0, y: h)
            context.scaleBy(x: 1, y: -1)
        }
        context.draw(shot.image, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let image = context.makeImage() else { return }
        undoStack.append(snapshot)
        redoStack.removeAll()
        renderer = AnnotationRenderer(shot: Shot(image: image, scale: shot.scale, app: shot.app))
        annotations = []
        crop = nil
        selected = nil
        updateFrame()
        onStateChange?()
    }

    private func restyleSelection(_ change: (inout Annotation) -> Void) {
        guard let index = selected, annotations.indices.contains(index) else { return }
        var list = annotations
        change(&list[index])
        commit(list)
    }

    /// The finished image: annotations baked in, cropped, and on the backdrop if chosen.
    func renderedShot() -> Shot {
        commitText()
        let shot = renderer.render(annotations, crop: crop)
        return background ? Backdrop.compose(shot) : shot
    }

    // MARK: Geometry

    var fullRect: NSRect { NSRect(origin: .zero, size: renderer.size) }
    var editingCrop: Bool { tool == .crop }
    /// The part of the image shown (the crop, unless the crop itself is being edited).
    private var shownArea: NSRect { editingCrop ? fullRect : (crop ?? fullRect) }
    private var padding: CGFloat { background && !editingCrop ? Backdrop.padding(for: shownArea.size) : 0 }
    private var documentSize: NSSize {
        NSSize(width: shownArea.width + padding * 2, height: shownArea.height + padding * 2)
    }

    private var availableSize: NSSize { enclosingScrollView?.contentSize ?? bounds.size }

    var fitZoom: CGFloat {
        let area = availableSize
        return max(0.05, min(1, (area.width - 48) / documentSize.width, (area.height - 48) / documentSize.height))
    }

    var zoom: CGFloat { zoomLevel ?? fitZoom }

    private var documentRect: NSRect {
        let size = NSSize(width: documentSize.width * zoom, height: documentSize.height * zoom)
        return NSRect(x: ((bounds.width - size.width) / 2).rounded(), y: ((bounds.height - size.height) / 2).rounded(),
                      width: size.width, height: size.height)
    }

    /// Grows the view past the scroll view when zoomed in, so it can be scrolled.
    func updateFrame() {
        let area = availableSize
        let size = NSSize(width: max(area.width, documentSize.width * zoom + 48),
                          height: max(area.height, documentSize.height * zoom + 48))
        if frame.size != size { setFrameSize(size) }
        needsDisplay = true
    }

    func viewPoint(_ p: NSPoint) -> NSPoint {
        let doc = documentRect
        return NSPoint(x: doc.minX + (padding + p.x - shownArea.minX) * zoom,
                       y: doc.minY + (padding + p.y - shownArea.minY) * zoom)
    }

    private func viewRect(_ r: NSRect) -> NSRect {
        let origin = viewPoint(r.origin)
        return NSRect(x: origin.x, y: origin.y, width: r.width * zoom, height: r.height * zoom)
    }

    func imagePoint(for event: NSEvent, clamp: Bool = true) -> NSPoint {
        let v = convert(event.locationInWindow, from: nil)
        let doc = documentRect
        var p = NSPoint(x: (v.x - doc.minX) / zoom - padding + shownArea.minX,
                        y: (v.y - doc.minY) / zoom - padding + shownArea.minY)
        if clamp {
            let area = shownArea
            p.x = min(max(p.x, area.minX), area.maxX)
            p.y = min(max(p.y, area.minY), area.maxY)
        }
        return p
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        NSColor(white: 0.13, alpha: 1).setFill()
        bounds.fill()
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let doc = documentRect
        let visible = shownArea
        let marks = annotations + (preview.map { [$0] } ?? [])

        context.saveGState()
        context.translateBy(x: doc.minX, y: doc.minY)
        context.scaleBy(x: zoom, y: zoom)
        let drawImage = {
            context.saveGState()
            context.translateBy(x: self.padding - visible.minX, y: self.padding - visible.minY)
            context.clip(to: visible)
            self.renderer.draw(marks)
            context.restoreGState()
        }
        if padding > 0 {
            Backdrop.drawBackground(in: NSRect(origin: .zero, size: documentSize))
            Backdrop.drawCard(NSRect(x: padding, y: padding, width: visible.width, height: visible.height), drawImage: drawImage)
        } else {
            NSGraphicsContext.saveGraphicsState()
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.5)
            shadow.shadowBlurRadius = 12
            shadow.set()
            NSColor.black.setFill()
            NSRect(origin: .zero, size: visible.size).fill()
            NSGraphicsContext.restoreGraphicsState()
            drawImage()
        }
        context.restoreGState()

        if editingCrop, let crop {
            let area = viewRect(crop)
            let dim = NSBezierPath(rect: viewRect(fullRect))
            dim.append(NSBezierPath(rect: area))
            dim.windingRule = .evenOdd
            NSColor.black.withAlphaComponent(0.55).setFill()
            dim.fill()
            NSColor.white.setStroke()
            let border = NSBezierPath(rect: area.insetBy(dx: 0.5, dy: 0.5))
            border.lineWidth = 1
            border.stroke()
            drawSizeLabel(crop.size, below: area)
        }

        if let index = selected, annotations.indices.contains(index) {
            let box = viewRect(annotations[index].bounds).insetBy(dx: -4, dy: -4)
            let path = NSBezierPath(roundedRect: box, xRadius: 3, yRadius: 3)
            path.lineWidth = 1
            path.setLineDash([4, 3], count: 2, phase: 0)
            NSColor.controlAccentColor.setStroke()
            path.stroke()
        }
    }

    private func drawSizeLabel(_ size: NSSize, below rect: NSRect) {
        let text = "\(Int(size.width)) × \(Int(size.height))" as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium), .foregroundColor: NSColor.white,
        ]
        let textSize = text.size(withAttributes: attributes)
        let box = NSRect(x: rect.midX - textSize.width / 2 - 6, y: rect.minY - textSize.height - 12,
                         width: textSize.width + 12, height: textSize.height + 4)
        NSColor.black.withAlphaComponent(0.75).setFill()
        NSBezierPath(roundedRect: box, xRadius: box.height / 2, yRadius: box.height / 2).fill()
        text.draw(at: NSPoint(x: box.minX + 6, y: box.minY + 2), withAttributes: attributes)
    }

    // MARK: Mouse (in CanvasView+Mouse.swift)

    // MARK: Keyboard (in CanvasView+Keyboard.swift)

    // MARK: Text (in CanvasView+Text.swift)
}
