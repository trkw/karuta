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
    private let colorPopup = NSPopUpButton(frame: .zero, pullsDown: true)
    private var widthSlider: NSSlider?
    /// The current tool's looks (arrow / text / pixelate / counter), swapped as the tool changes.
    private let optionsStack = NSStackView()
    private var optionsTool: Tool?
    private var optionsSegment: NSSegmentedControl?
    private var counterField: NSTextField?
    private var usesColorPanel = false
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
        if usesColorPanel {
            NSColorPanel.shared.setTarget(nil)
            NSColorPanel.shared.setAction(nil)
        }
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

        let transforms: [(String, String, CanvasView.Transform)] = [
            ("rotate.left", "左に回転", .rotateLeft), ("rotate.right", "右に回転", .rotateRight),
            ("arrow.left.and.right.righttriangle.left.righttriangle.right", "左右反転", .flipHorizontal),
            ("arrow.up.and.down.righttriangle.up.righttriangle.down", "上下反転", .flipVertical),
        ]
        let left = NSStackView(views: [zoomPopup] + transforms.map { symbol, label, transform in
            RoundIconButton(symbol: symbol, label: label) { [weak self] _ in
                guard let self else { return }
                self.canvas.apply(transform)
                self.window?.makeFirstResponder(self.canvas)
            }
        })
        left.spacing = 8
        left.setCustomSpacing(14, after: zoomPopup)

        for view in [left, handle, right] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            bar.addSubview(view)
        }
        NSLayoutConstraint.activate([
            left.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: 14),
            left.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
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
        static let options = NSToolbarItem.Identifier("options")
        static let width = NSToolbarItem.Identifier("width")
        static let save = NSToolbarItem.Identifier("save")
        static let done = NSToolbarItem.Identifier("done")
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [Item.leading, Item.tools, Item.style, Item.width, Item.options, .flexibleSpace, Item.save, Item.done]
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
            widthSlider = slider
            item.view = slider
        case Item.options:
            optionsStack.spacing = 6
            item.view = optionsStack
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
        colorPopup.toolTip = "色"
        rebuildColorMenu()
        return colorPopup
    }

    /// The color menu: the current color on the button, then the basic colors, the saved ones,
    /// and ways to pick any color.
    private func rebuildColorMenu() {
        let menu = NSMenu()
        let current = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        current.image = Self.swatch(canvas.color)
        menu.addItem(current) // a pull-down's first item is its button face
        let addColor = { [weak self] (color: NSColor) in
            menu.addItem(MenuAction(title: "") { [weak self] in self?.choose(color) })
            menu.items.last?.image = Self.swatch(color)
        }
        Self.colors.forEach(addColor)
        let saved = Preferences.savedColors
        if !saved.isEmpty {
            menu.addItem(.separator())
            saved.forEach(addColor)
        }
        menu.addItem(.separator())
        menu.addItem(MenuAction(title: "画面から色を取る…") { [weak self] in
            NSColorSampler().show { color in
                guard let color else { return }
                // The sampler calls this on the main thread.
                MainActor.assumeIsolated { self?.choose(color) }
            }
        })
        menu.addItem(MenuAction(title: "ほかの色…") { [weak self] in self?.showColorPanel() })
        menu.addItem(MenuAction(title: "今の色を保存") { [weak self] in
            guard let self else { return }
            let color = self.canvas.color
            Preferences.savedColors = [color] + Preferences.savedColors.filter { !$0.isSame(as: color) }
            self.rebuildColorMenu()
        })
        if !saved.isEmpty {
            menu.addItem(MenuAction(title: "保存した色を消去") { [weak self] in
                Preferences.savedColors = []
                self?.rebuildColorMenu()
            })
        }
        colorPopup.menu = menu
    }

    private func choose(_ color: NSColor) {
        canvas.color = color
        rebuildColorMenu()
        window?.makeFirstResponder(canvas)
    }

    private func showColorPanel() {
        let panel = NSColorPanel.shared
        panel.showsAlpha = true
        panel.color = canvas.color
        panel.setTarget(self)
        panel.setAction(#selector(colorPanelChanged(_:)))
        usesColorPanel = true
        panel.orderFront(nil)
    }

    @objc private func colorPanelChanged(_ sender: NSColorPanel) {
        canvas.color = sender.color
        rebuildColorMenu()
    }

    /// Shows the looks of the tool in use (or of the selected mark).
    private func updateOptions() {
        let target = canvas.styleTarget
        if target != optionsTool {
            optionsTool = target
            optionsStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
            optionsSegment = nil
            counterField = nil
            if let target { buildOptions(for: target) }
        }
        if target != nil, let segment = optionsSegment { segment.selectedSegment = canvas.shownStyle }
        if let field = counterField, field.currentEditor() == nil { field.integerValue = canvas.nextCounter }
    }

    private func buildOptions(for tool: Tool) {
        let segment: NSSegmentedControl
        switch tool {
        case .arrow:
            segment = NSSegmentedControl(images: ArrowStyle.allCases.map {
                NSImage(systemSymbolName: $0.symbol, accessibilityDescription: $0.title) ?? NSImage()
            }, trackingMode: .selectOne, target: self, action: #selector(styleChosen(_:)))
            for (index, style) in ArrowStyle.allCases.enumerated() { segment.setToolTip(style.title, forSegment: index) }
        case .text:
            segment = NSSegmentedControl(labels: TextStyle.allCases.map(\.title), trackingMode: .selectOne,
                                         target: self, action: #selector(styleChosen(_:)))
        case .pixelate:
            segment = NSSegmentedControl(labels: PixelateStyle.allCases.map(\.title), trackingMode: .selectOne,
                                         target: self, action: #selector(styleChosen(_:)))
        case .counter:
            segment = NSSegmentedControl(labels: CounterStyle.allCases.map(\.title), trackingMode: .selectOne,
                                         target: self, action: #selector(styleChosen(_:)))
        default:
            return
        }
        segment.controlSize = .small
        optionsSegment = segment
        optionsStack.addArrangedSubview(segment)
        if tool == .counter {
            let label = NSTextField(labelWithString: "次:")
            label.font = .systemFont(ofSize: 11)
            label.textColor = .secondaryLabelColor
            let field = NSTextField(string: "")
            field.controlSize = .small
            field.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
            field.alignment = .center
            field.formatter = {
                let formatter = NumberFormatter()
                formatter.allowsFloats = false
                formatter.minimum = 0
                return formatter
            }()
            field.toolTip = "次に置く番号"
            field.target = self
            field.action = #selector(counterStartChanged(_:))
            field.widthAnchor.constraint(equalToConstant: 40).isActive = true
            counterField = field
            optionsStack.addArrangedSubview(label)
            optionsStack.addArrangedSubview(field)
        }
    }

    @objc private func styleChosen(_ sender: NSSegmentedControl) {
        guard let tool = optionsTool else { return }
        canvas.setStyle(sender.selectedSegment, for: tool)
        window?.makeFirstResponder(canvas)
    }

    @objc private func counterStartChanged(_ sender: NSTextField) {
        canvas.nextCounter = sender.integerValue
        window?.makeFirstResponder(canvas)
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
        widthSlider?.doubleValue = Double(canvas.lineWidth)
        updateOptions()
    }

    // MARK: - Commands

    private func handleCommand(_ key: String, shift: Bool) -> Bool {
        // Typing in the canvas's text or a toolbar field (the counter's number): editing shortcuts go to the text.
        if canvas.isEditingText || window?.firstResponder is NSText {
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
        case ("d", false): return canvas.duplicateSelection()
        case ("p", false): printImage()
        case ("z", false): canvas.undo()
        case ("z", true): canvas.redo()
        case ("w", _): close()
        default: return false
        }
        return true
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
        let save = ImageSavePanel(shot: canvas.renderedShot())
        save.panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK else { return }
            do {
                try save.write()
                self?.close()
            } catch {
                self?.showError(error)
            }
        }
    }

    private func printImage() {
        guard let window else { return }
        let shot = canvas.renderedShot()
        let size = NSSize(width: CGFloat(shot.image.width) / shot.scale, height: CGFloat(shot.image.height) / shot.scale)
        let view = NSImageView(frame: NSRect(origin: .zero, size: size))
        view.image = NSImage(cgImage: shot.image, size: size)
        view.imageScaling = .scaleProportionallyUpOrDown
        let info = NSPrintInfo.shared.copy() as! NSPrintInfo
        info.horizontalPagination = .fit
        info.verticalPagination = .fit
        info.isHorizontallyCentered = true
        info.isVerticallyCentered = true
        if size.width > size.height { info.orientation = .landscape }
        NSPrintOperation(view: view, printInfo: info).runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
    }

    private func share(from sender: NSView) {
        guard let url = Exporter.writeTemporary(canvas.renderedShot()) else { return }
        NSSharingServicePicker(items: [url]).show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
    }

    private func showError(_ error: Error) {
        if let window { SaveErrorAlert.show(error, sheetOn: window) }
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
