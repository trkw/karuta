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

    private let canvas: CanvasView
    private let scrollView = NSScrollView()
    private var toolButtons: [Tool: ToolButton] = [:]
    private var backgroundButton: ToolButton?
    private let zoomPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private static let zoomChoices: [(String, CGFloat?)] = [("フィット", nil), ("50%", 0.5), ("100%", 1), ("200%", 2)]

    private static let colors: [NSColor] = [
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
        onClose?()
    }

    func windowDidResize(_ notification: Notification) {
        canvas.updateFrame()
    }

    // MARK: - Layout

    private func buildContent(size: NSSize) {
        let content = NSView(frame: NSRect(origin: .zero, size: size))
        let bottomBar = makeBottomBar()
        bottomBar.translatesAutoresizingMaskIntoConstraints = false

        scrollView.drawsBackground = true
        scrollView.backgroundColor = NSColor(white: 0.13, alpha: 1)
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.documentView = canvas
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        content.addSubview(scrollView)
        content.addSubview(bottomBar)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: content.safeAreaLayoutGuide.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomBar.topAnchor),
            bottomBar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            bottomBar.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            bottomBar.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            bottomBar.heightAnchor.constraint(equalToConstant: 48),
        ])
        window?.contentView = content
        content.layoutSubtreeIfNeeded()
        canvas.updateFrame()
    }

    private func makeBottomBar() -> NSView {
        let bar = BarView()

        for (title, _) in Self.zoomChoices { zoomPopup.addItem(withTitle: title) }
        zoomPopup.controlSize = .small
        zoomPopup.target = self
        zoomPopup.action = #selector(zoomChanged)

        let handle = DragHandle { [weak self] in
            guard let self else { return nil }
            return Exporter.writeTemporary(self.canvas.renderedShot())
        }

        let share = RoundIconButton(symbol: "square.and.arrow.up", label: "共有") { [weak self] sender in self?.share(from: sender) }
        let pin = RoundIconButton(symbol: "pin.fill", label: "ピン留め") { [weak self] _ in self?.pinImage() }
        let copy = RoundIconButton(symbol: "doc.on.doc", label: "コピー (⌘C)") { [weak self] _ in self?.copyImage() }
        let right = NSStackView(views: [share, pin, copy])
        right.spacing = 8

        for view in [zoomPopup, handle, right] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            bar.addSubview(view)
        }
        NSLayoutConstraint.activate([
            zoomPopup.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: 14),
            zoomPopup.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            handle.centerXAnchor.constraint(equalTo: bar.centerXAnchor),
            handle.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            right.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -14),
            right.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
        ])
        return bar
    }

    // MARK: - Toolbar

    private enum Item {
        static let leading = NSToolbarItem.Identifier("leading")
        static let tools = NSToolbarItem.Identifier("tools")
        static let style = NSToolbarItem.Identifier("style")
        static let width = NSToolbarItem.Identifier("width")
        static let save = NSToolbarItem.Identifier("save")
        static let done = NSToolbarItem.Identifier("done")
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [Item.leading, Item.tools, Item.style, Item.width, .flexibleSpace, Item.save, Item.done]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        let item = NSToolbarItem(itemIdentifier: identifier)
        switch identifier {
        case Item.leading:
            let crop = toolButton(.crop)
            let background = ToolButton(symbol: "photo.artframe", label: "背景 (B)") { [weak self] in
                self?.showBackdropPanel()
            }
            background.isOn = canvas.background
            backgroundButton = background
            item.view = group([crop, background], separated: true)
        case Item.tools:
            let tools = Tool.allCases.filter { $0 != .crop }.map(toolButton)
            item.view = group(tools, separated: false)
        case Item.style:
            item.view = makeColorPopup()
        case Item.width:
            let slider = NSSlider(value: Double(canvas.lineWidth), minValue: 1, maxValue: 12,
                                  target: self, action: #selector(widthChanged(_:)))
            slider.controlSize = .small
            slider.toolTip = "太さ"
            slider.widthAnchor.constraint(equalToConstant: 96).isActive = true
            item.view = slider
        case Item.save:
            let button = NSButton(title: "Save as…", target: self, action: #selector(saveAs))
            button.bezelStyle = .rounded
            item.view = button
        case Item.done:
            let button = NSButton(title: "Done", target: self, action: #selector(done))
            button.bezelStyle = .rounded
            button.keyEquivalent = "\r" // the blue default button
            item.view = button
        default:
            return nil
        }
        return item
    }

    private func toolButton(_ tool: Tool) -> ToolButton {
        let button = ToolButton(symbol: tool.symbol, label: "\(tool.title) (\(tool.key.uppercased()))") { [weak self] in
            guard let self else { return }
            self.canvas.tool = self.canvas.tool == tool && tool == .crop ? .select : tool
            self.window?.makeFirstResponder(self.canvas)
        }
        toolButtons[tool] = button
        return button
    }

    /// A rounded capsule holding buttons, like CleanShot's toolbar groups.
    private func group(_ buttons: [NSView], separated: Bool) -> NSView {
        let stack = NSStackView(views: buttons)
        stack.spacing = separated ? 6 : 2
        stack.edgeInsets = NSEdgeInsets(top: 2, left: 4, bottom: 2, right: 4)
        let capsule = CapsuleView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        capsule.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: capsule.topAnchor),
            stack.bottomAnchor.constraint(equalTo: capsule.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: capsule.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: capsule.trailingAnchor),
        ])
        return capsule
    }

    private func makeColorPopup() -> NSView {
        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        for color in Self.colors {
            popup.addItem(withTitle: "")
            popup.lastItem?.image = Self.swatch(color)
        }
        popup.target = self
        popup.action = #selector(colorChanged(_:))
        popup.toolTip = "色"
        return popup
    }

    /// Turns the backdrop on and opens its options (gradient, color, wallpaper, picture, padding).
    private func showBackdropPanel() {
        guard let button = backgroundButton else { return }
        if !canvas.background { canvas.background = true }
        let popover = NSPopover()
        popover.behavior = .semitransient
        popover.contentViewController = BackdropPanel(canvas: canvas)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }

    private func syncControls() {
        for (tool, button) in toolButtons { button.isOn = canvas.tool == tool }
        backgroundButton?.isOn = canvas.background
    }

    // MARK: - Commands

    private func handleCommand(_ key: String, shift: Bool) -> Bool {
        if canvas.isEditingText {
            // Without an Edit menu, the text field's standard editing shortcuts need to be sent by hand.
            let actions: [String: Selector] = [
                "c": #selector(NSText.copy(_:)), "v": #selector(NSText.paste(_:)),
                "x": #selector(NSText.cut(_:)), "a": #selector(NSText.selectAll(_:)),
            ]
            guard let action = actions[key] else { return false }
            return NSApp.sendAction(action, to: nil, from: self)
        }
        switch (key, shift) {
        case ("c", false): copyImage()
        case ("s", false): saveToFolder()
        case ("s", true): saveAs()
        case ("z", false): canvas.undo()
        case ("z", true): canvas.redo()
        case ("w", _): close()
        default: return false
        }
        return true
    }

    @objc private func colorChanged(_ sender: NSPopUpButton) {
        canvas.color = Self.colors[sender.indexOfSelectedItem]
        window?.makeFirstResponder(canvas)
    }

    @objc private func widthChanged(_ sender: NSSlider) {
        canvas.lineWidth = CGFloat(sender.doubleValue.rounded())
    }

    @objc private func zoomChanged() {
        canvas.zoomLevel = Self.zoomChoices[zoomPopup.indexOfSelectedItem].1
        window?.makeFirstResponder(canvas)
    }

    @objc private func done() {
        // Return while cropping applies the crop instead of finishing.
        if canvas.tool == .crop, NSApp.currentEvent?.type == .keyDown {
            canvas.tool = .select
            return
        }
        onDone?(canvas.renderedShot())
        close()
    }

    private func copyImage() {
        Exporter.copy(canvas.renderedShot())
        close()
    }

    private func pinImage() {
        let frame = window?.frame ?? .zero
        onPin?(canvas.renderedShot(), frame)
        close()
    }

    private func saveToFolder() {
        do {
            try Exporter.save(canvas.renderedShot())
            close()
        } catch {
            showError(error)
        }
    }

    @objc private func saveAs() {
        guard let window else { return }
        let format = Preferences.format
        let panel = NSSavePanel()
        panel.allowedContentTypes = [format == .png ? .png : .jpeg]
        panel.directoryURL = Preferences.saveDirectory
        panel.nameFieldStringValue = Exporter.defaultFileName(extension: format.fileExtension)
        let shot = canvas.renderedShot()
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            do {
                guard let data = Exporter.fileData(shot, format: format) else { throw CocoaError(.fileWriteUnknown) }
                try data.write(to: url)
                self?.close()
            } catch {
                self?.showError(error)
            }
        }
    }

    private func share(from sender: NSView) {
        guard let url = Exporter.writeTemporary(canvas.renderedShot()) else { return }
        NSSharingServicePicker(items: [url]).show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
    }

    private func showError(_ error: Error) {
        let alert = NSAlert(error: error)
        alert.messageText = "保存できませんでした"
        if let window { alert.beginSheetModal(for: window) }
    }

    private static func swatch(_ color: NSColor) -> NSImage {
        NSImage(size: NSSize(width: 14, height: 14), flipped: false) { rect in
            color.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1)).fill()
            NSColor.white.withAlphaComponent(0.4).setStroke()
            NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1)).stroke()
            return true
        }
    }
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

// MARK: - Controls

/// A toolbar tool: an SF Symbol that turns into white-on-blue when active, like CleanShot.
final class ToolButton: NSButton {
    var isOn = false { didSet { needsDisplay = true } }
    private let symbol: NSImage?
    private let handler: () -> Void

    init(symbol name: String, label: String, handler: @escaping () -> Void) {
        symbol = NSImage(systemSymbolName: name, accessibilityDescription: label)?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .medium))
        self.handler = handler
        super.init(frame: .zero)
        title = ""
        isBordered = false
        toolTip = label
        setAccessibilityLabel(label)
        target = self
        action = #selector(fire)
        widthAnchor.constraint(equalToConstant: 32).isActive = true
        heightAnchor.constraint(equalToConstant: 26).isActive = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    @objc private func fire() { handler() }

    override func draw(_ dirtyRect: NSRect) {
        if isOn {
            NSColor.controlAccentColor.setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 6, yRadius: 6).fill()
        }
        guard let symbol else { return }
        let tint: NSColor = isOn ? .white : .labelColor
        let tinted = NSImage(size: symbol.size, flipped: false) { rect in
            symbol.draw(in: rect)
            tint.set()
            rect.fill(using: .sourceAtop)
            return true
        }
        tinted.draw(in: NSRect(x: (bounds.midX - symbol.size.width / 2).rounded(),
                               y: (bounds.midY - symbol.size.height / 2).rounded(),
                               width: symbol.size.width, height: symbol.size.height))
    }
}

private final class CapsuleView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor.labelColor.withAlphaComponent(0.08).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8).fill()
    }
}

/// The bottom bar's background with a hairline on top.
private final class BarView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor(white: 0.18, alpha: 1).setFill()
        bounds.fill()
        NSColor(white: 1, alpha: 0.08).setFill()
        NSRect(x: 0, y: bounds.maxY - 1, width: bounds.width, height: 1).fill()
    }
}

/// A round dark button with a symbol (share, pin, copy).
private final class RoundIconButton: NSButton {
    private let symbol: NSImage?
    private let handler: (NSView) -> Void

    init(symbol name: String, label: String, handler: @escaping (NSView) -> Void) {
        symbol = NSImage(systemSymbolName: name, accessibilityDescription: label)?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .semibold))
        self.handler = handler
        super.init(frame: .zero)
        title = ""
        isBordered = false
        toolTip = label
        setAccessibilityLabel(label)
        target = self
        action = #selector(fire)
        widthAnchor.constraint(equalToConstant: 34).isActive = true
        heightAnchor.constraint(equalToConstant: 28).isActive = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    @objc private func fire() { handler(self) }

    override func draw(_ dirtyRect: NSRect) {
        NSColor(white: 1, alpha: isHighlighted ? 0.2 : 0.1).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2).fill()
        guard let symbol else { return }
        let tinted = NSImage(size: symbol.size, flipped: false) { rect in
            symbol.draw(in: rect)
            NSColor.white.set()
            rect.fill(using: .sourceAtop)
            return true
        }
        tinted.draw(in: NSRect(x: (bounds.midX - symbol.size.width / 2).rounded(),
                               y: (bounds.midY - symbol.size.height / 2).rounded(),
                               width: symbol.size.width, height: symbol.size.height))
    }
}

/// "Drag Me": drag the edited image out as a file.
private final class DragHandle: NSView, NSDraggingSource {
    private let makeFile: () -> URL?

    init(makeFile: @escaping () -> URL?) {
        self.makeFile = makeFile
        super.init(frame: .zero)
        toolTip = "ドラッグして他のアプリへ渡す"
        widthAnchor.constraint(equalToConstant: 150).isActive = true
        heightAnchor.constraint(equalToConstant: 28).isActive = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .openHand)
    }

    override func draw(_ dirtyRect: NSRect) {
        let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: bounds.height / 2,
                                 yRadius: bounds.height / 2)
        NSColor(white: 1, alpha: 0.06).setFill()
        shape.fill()
        NSColor(white: 1, alpha: 0.15).setStroke()
        shape.stroke()

        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium), .foregroundColor: NSColor.secondaryLabelColor,
        ]
        let text = "Drag Me" as NSString
        let size = text.size(withAttributes: attributes)
        text.draw(at: NSPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2), withAttributes: attributes)
        // Grip lines on both sides.
        NSColor.tertiaryLabelColor.setFill()
        for x in [bounds.minX + 16, bounds.maxX - 26] {
            for i in 0 ..< 3 {
                NSRect(x: x, y: bounds.midY - 4 + CGFloat(i) * 4, width: 10, height: 1).fill()
            }
        }
    }

    override func mouseDown(with event: NSEvent) {}

    override func mouseDragged(with event: NSEvent) {
        guard let url = makeFile() else { return }
        let item = NSDraggingItem(pasteboardWriter: url as NSURL)
        let icon = NSImage(contentsOf: url) ?? NSImage()
        let width: CGFloat = 120
        let height = icon.size.width > 0 ? width * icon.size.height / icon.size.width : width
        let point = convert(event.locationInWindow, from: nil)
        item.setDraggingFrame(NSRect(x: point.x - width / 2, y: point.y - height / 2, width: width, height: height),
                              contents: icon)
        beginDraggingSession(with: [item], event: event, source: self)
    }

    func draggingSession(_ session: NSDraggingSession,
                         sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .copy
    }
}
