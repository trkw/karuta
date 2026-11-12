import AppKit
import UniformTypeIdentifiers

/// CleanShot-style annotation editor: a dark window with the tools in a unified toolbar
/// (crop and background, then the drawing tools, color, width, Save as… and Done), and a bottom bar
/// with zoom, a drag handle and share / pin / copy buttons.
@MainActor
final class EditorWindowController: NSWindowController, NSWindowDelegate, NSToolbarDelegate {
    var onClose: (() -> Void)?
    /// Done: the edited image goes back to Quick Access.
    var onDone: ((Shot) -> Void)?
    var onPin: ((Shot, NSRect) -> Void)?

    let canvas: CanvasView
    let scrollView = NSScrollView()
    var toolButtons: [Tool: ToolButton] = [:]
    var backgroundButton: ToolButton?
    let zoomPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    let colorPopup = NSPopUpButton(frame: .zero, pullsDown: true)
    var widthSlider: NSSlider?
    /// The current tool's looks (arrow / text / pixelate / counter), swapped as the tool changes.
    let optionsStack = NSStackView()
    var optionsTool: Tool?
    var optionsSegment: NSSegmentedControl?
    var counterField: NSTextField?
    var usesColorPanel = false
    static let zoomChoices: [(String, CGFloat?)] = [("フィット", nil), ("50%", 0.5), ("100%", 1), ("200%", 2)]

    static let colors: [NSColor] = [
        .systemRed, .systemOrange, .systemYellow, .systemGreen, .systemBlue, .systemPurple, .white, .black,
    ]

    init(shot: Shot, background: Bool = false) {
        let canvas = CanvasView(renderer: AnnotationRenderer(shot: shot))
        canvas.background = background
        self.canvas = canvas

        let chrome: CGFloat = 52 + 48 // toolbar + bottom bar
        let visible = NSScreen.underMouse.visibleFrame
        let imageSize = canvas.renderer.size
        let fit = min(1, visible.width * 0.85 / imageSize.width, (visible.height * 0.85 - chrome) / imageSize.height)
        let contentSize = NSSize(width: max(imageSize.width * fit + 96, 960),
                                 height: max(imageSize.height * fit + 96, 360) + chrome)

        let window = EditorWindow(contentRect: NSRect(origin: .zero, size: contentSize),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                                  backing: .buffered, defer: false)
        window.title = "Karuta"
        window.titleVisibility = .hidden
        window.appearance = NSAppearance(named: .darkAqua)
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 820, height: 420)
        super.init(window: window)
        window.delegate = self
        window.keyHandler = { [weak self] key, shift in self?.handleCommand(key, shift: shift) ?? false }

        let toolbar = NSToolbar(identifier: "KarutaEditor")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        window.toolbar = toolbar
        window.toolbarStyle = .unified

        buildContent(size: contentSize)
        canvas.onStateChange = { [weak self] in self?.syncControls() }
        syncControls()
        window.center()
        window.makeFirstResponder(canvas)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func windowWillClose(_ notification: Notification) {
        if usesColorPanel {
            NSColorPanel.shared.setTarget(nil)
            NSColorPanel.shared.setAction(nil)
        }
        onClose?()
    }

    func windowDidResize(_ notification: Notification) {
        canvas.updateFrame()
    }

    // MARK: - Layout (in EditorWindowController+Layout.swift)

    // MARK: - Toolbar (in EditorWindowController+Toolbar.swift)

    // MARK: - Commands (in EditorWindowController+Commands.swift)
}

/// The app has no main menu, so ⌘-shortcuts are routed here.
private final class EditorWindow: NSWindow {
    var keyHandler: ((String, Bool) -> Bool)?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.subtracting(.shift) == .command,
           let key = event.charactersIgnoringModifiers?.lowercased(),
           keyHandler?(key, flags.contains(.shift)) == true {
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}
