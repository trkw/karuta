import AppKit

/// The bar under an All-In-One area: its size (type to change), an aspect-ratio lock, and the ways to finish
/// (self-timer, pin, annotate, save, copy, capture). Lives inside the selection overlay, so it's never captured.
final class AllInOneBar: NSView {
    var onSize: ((NSSize) -> Void)?
    var onAspect: ((CGFloat?) -> Void)?
    var onAction: ((SelectionController.Action) -> Void)?

    private static let aspects: [(String, CGFloat?)] = [
        ("フリー", nil), ("1:1", 1), ("4:3", 4.0 / 3), ("3:2", 3.0 / 2), ("5:4", 5.0 / 4),
        ("16:9", 16.0 / 9), ("9:16", 9.0 / 16),
    ]

    private let widthField = AllInOneBar.numberField()
    private let heightField = AllInOneBar.numberField()
    private let aspectPopup = NSPopUpButton(frame: .zero, pullsDown: false)

    init() {
        super.init(frame: .zero)
        appearance = NSAppearance(named: .darkAqua)
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.backgroundColor = NSColor(white: 0.12, alpha: 0.92).cgColor
        layer?.borderWidth = 1
        layer?.borderColor = NSColor(white: 1, alpha: 0.12).cgColor

        for field in [widthField, heightField] {
            field.target = self
            field.action = #selector(sizeEdited)
        }
        let times = NSTextField(labelWithString: "×")
        times.textColor = .secondaryLabelColor

        aspectPopup.addItems(withTitles: Self.aspects.map(\.0))
        aspectPopup.controlSize = .small
        aspectPopup.target = self
        aspectPopup.action = #selector(aspectChosen)
        aspectPopup.toolTip = "縦横比を固定"

        let actions: [(String, String, SelectionController.Action)] = [
            ("timer", "セルフタイマー", .timer), ("pin", "ピン留め", .pin), ("pencil", "編集", .annotate),
            ("square.and.arrow.down", "保存", .save), ("doc.on.doc", "コピー", .copy),
        ]
        var buttons: [NSView] = actions.map { symbol, label, action in
            let button = BarButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: label)) {
                [weak self] in self?.onAction?(action)
            }
            button.toolTip = label
            return button
        }
        let capture = BarButton(title: "撮影") { [weak self] in self?.onAction?(.capture) }
        capture.bezelColor = .controlAccentColor
        capture.toolTip = "撮影（Return）"
        buttons.append(capture)

        let divider = NSBox()
        divider.boxType = .separator
        let stack = NSStackView(views: [widthField, times, heightField, aspectPopup, divider] + buttons)
        stack.orientation = .horizontal
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 6, left: 8, bottom: 6, right: 8)
        stack.setCustomSpacing(12, after: aspectPopup)
        stack.setCustomSpacing(12, after: divider)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            divider.heightAnchor.constraint(equalToConstant: 18),
        ])
        setFrameSize(stack.fittingSize)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// Shows the area's size (unless a field is being typed in) and the current lock.
    func show(size: NSSize, aspect: CGFloat?) {
        if widthField.currentEditor() == nil { widthField.integerValue = Int(size.width) }
        if heightField.currentEditor() == nil { heightField.integerValue = Int(size.height) }
        aspectPopup.selectItem(at: Self.aspects.firstIndex { $0.1 == aspect } ?? 0)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    // Clicks on the bar's background shouldn't fall through and start a new area.
    override func mouseDown(with event: NSEvent) {}

    @objc private func sizeEdited() {
        let width = max(widthField.integerValue, 4), height = max(heightField.integerValue, 4)
        onSize?(NSSize(width: width, height: height))
    }

    @objc private func aspectChosen() {
        onAspect?(Self.aspects[aspectPopup.indexOfSelectedItem].1)
    }

    private static func numberField() -> NSTextField {
        let field = NSTextField(string: "")
        field.alignment = .center
        field.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        field.controlSize = .small
        field.formatter = {
            let formatter = NumberFormatter()
            formatter.allowsFloats = false
            formatter.minimum = 1
            return formatter
        }()
        field.widthAnchor.constraint(equalToConstant: 52).isActive = true
        return field
    }
}

private final class BarButton: NSButton {
    private let handler: () -> Void

    init(image: NSImage?, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(frame: .zero)
        self.image = image
        imagePosition = .imageOnly
        commonInit()
    }

    init(title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(frame: .zero)
        self.title = title
        commonInit()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func commonInit() {
        bezelStyle = .rounded
        controlSize = .small
        target = self
        action = #selector(fire)
    }

    @objc private func fire() { handler() }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
