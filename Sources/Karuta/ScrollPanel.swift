import AppKit

// MARK: - Panel

/// The controls under the area while capturing: what to do, the height so far, and Done / Cancel.
/// It never takes focus, so the page under it keeps receiving the scroll.
final class ScrollPanel: NSPanel {
    var onDone: (() -> Void)?
    var onCancel: (() -> Void)?
    var onAutoScroll: (() -> Void)?

    private let message = NSTextField(labelWithString: "スクロールしてください")
    private let size = NSTextField(labelWithString: "")

    init(below rect: CGRect, on screen: NSScreen) {
        let panelSize = NSSize(width: 420, height: 44)
        let visible = screen.visibleFrame
        var origin = NSPoint(x: rect.midX - panelSize.width / 2, y: rect.minY - panelSize.height - 12)
        if origin.y < visible.minY { origin.y = min(rect.maxY + 12, visible.maxY - panelSize.height) }
        if origin.y + panelSize.height > visible.maxY { origin.y = rect.minY + 12 } // area fills the screen: inside it
        origin.x = min(max(origin.x, visible.minX + 8), visible.maxX - panelSize.width - 8)
        super.init(contentRect: NSRect(origin: origin, size: panelSize), styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        level = .screenSaver
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        appearance = NSAppearance(named: .darkAqua)

        let background = NSView(frame: NSRect(origin: .zero, size: panelSize))
        background.wantsLayer = true
        background.layer?.cornerRadius = 10
        background.layer?.backgroundColor = NSColor(white: 0.12, alpha: 0.92).cgColor

        message.font = .systemFont(ofSize: 12, weight: .medium)
        message.textColor = .white
        message.lineBreakMode = .byTruncatingTail
        size.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        size.textColor = .secondaryLabelColor
        let auto = Self.button("自動スクロール") { [weak self] in self?.onAutoScroll?() }
        let cancel = Self.button("キャンセル") { [weak self] in self?.onCancel?() }
        let done = Self.button("完了") { [weak self] in self?.onDone?() }
        done.bezelColor = .controlAccentColor

        let texts = NSStackView(views: [message, size])
        texts.orientation = .vertical
        texts.alignment = .leading
        texts.spacing = 0
        texts.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let stack = NSStackView(views: [texts, auto, cancel, done])
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 6, left: 12, bottom: 6, right: 8)
        stack.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            stack.centerYAnchor.constraint(equalTo: background.centerYAnchor),
        ])
        contentView = background
    }

    func show(height pixels: Int, scale: CGFloat) {
        size.stringValue = "高さ \(Int(CGFloat(pixels) / max(scale, 1))) pt"
    }

    func showMessage(_ text: String) {
        message.stringValue = text
    }

    private static func button(_ title: String, action: @escaping () -> Void) -> NSButton {
        let button = PanelButton(title: title, action: action)
        button.bezelStyle = .rounded
        button.controlSize = .small
        return button
    }

    private final class PanelButton: NSButton {
        private let handler: () -> Void

        init(title: String, action: @escaping () -> Void) {
            handler = action
            super.init(frame: .zero)
            self.title = title
            target = self
            self.action = #selector(fire)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError() }

        @objc private func fire() { handler() }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    }
}
