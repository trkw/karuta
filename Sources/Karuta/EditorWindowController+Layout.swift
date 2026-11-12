import AppKit

// Layout: the window's content, the canvas in its scroll view and the bottom bar.
extension EditorWindowController {
    func buildContent(size: NSSize) {
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
}
