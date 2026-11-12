import AppKit

// Toolbar: the tools, colour, width and style controls, and the NSToolbarDelegate items.
extension EditorWindowController {
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

    func syncControls() {
        for (tool, button) in toolButtons { button.isOn = canvas.tool == tool }
        backgroundButton?.isOn = canvas.background
        widthSlider?.doubleValue = Double(canvas.lineWidth)
        updateOptions()
    }
}
