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

    // MARK: Looks (in CanvasView+Looks.swift)

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

    func restyleSelection(_ change: (inout Annotation) -> Void) {
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

    // MARK: Geometry (in CanvasView+Geometry.swift)

    // MARK: Drawing (in CanvasView+Drawing.swift)

    // MARK: Mouse (in CanvasView+Mouse.swift)

    // MARK: Keyboard (in CanvasView+Keyboard.swift)

    // MARK: Text (in CanvasView+Text.swift)
}
