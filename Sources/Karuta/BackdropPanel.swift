import AppKit
import UniformTypeIdentifiers

/// The popover under the editor's background button: none / gradient / color / wallpaper / picture, plus padding.
/// Choices are saved in Preferences, so the next shot gets the same backdrop.
@MainActor
final class BackdropPanel: NSViewController {
    private let canvas: CanvasView
    private let modes = NSSegmentedControl()
    private let gradientRow = NSStackView()
    private let colorRow = NSStackView()
    private let imageRow = NSStackView()
    private let imageName = NSTextField(labelWithString: "")
    private let colorWell = NSColorWell(style: .minimal)

    init(canvas: CanvasView) {
        self.canvas = canvas
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private static let styles: [Preferences.BackdropStyle?] = [nil] + Preferences.BackdropStyle.allCases

    override func loadView() {
        modes.segmentCount = Self.styles.count
        for (index, style) in Self.styles.enumerated() {
            modes.setLabel(style?.title ?? "なし", forSegment: index)
        }
        modes.trackingMode = .selectOne
        modes.target = self
        modes.action = #selector(modeChanged)

        gradientRow.spacing = 6
        for index in Backdrop.gradients.indices {
            gradientRow.addArrangedSubview(GradientSwatch(index: index) { [weak self] in
                Preferences.backdropGradient = index
                self?.sync()
            })
        }

        colorWell.color = Preferences.backdropColor
        colorWell.target = self
        colorWell.action = #selector(colorChanged)
        colorRow.addArrangedSubview(NSTextField(labelWithString: "色"))
        colorRow.addArrangedSubview(colorWell)

        imageName.lineBreakMode = .byTruncatingMiddle
        imageName.textColor = .secondaryLabelColor
        imageName.widthAnchor.constraint(lessThanOrEqualToConstant: 220).isActive = true
        imageRow.addArrangedSubview(NSButton(title: "画像を選択…", target: self, action: #selector(chooseImage)))
        imageRow.addArrangedSubview(imageName)

        let padding = NSSlider(value: Double(Preferences.backdropPadding), minValue: 2, maxValue: 20,
                               target: self, action: #selector(paddingChanged(_:)))
        padding.controlSize = .small
        padding.widthAnchor.constraint(equalToConstant: 180).isActive = true
        let paddingRow = NSStackView(views: [NSTextField(labelWithString: "余白"), padding])

        let stack = NSStackView(views: [modes, gradientRow, colorRow, imageRow, paddingRow])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14)
        view = stack
        sync()
    }

    /// Shows the rows that belong to the current mode.
    private func sync() {
        let style = canvas.background ? Preferences.backdropStyle : nil
        modes.selectedSegment = Self.styles.firstIndex(of: style) ?? 0
        gradientRow.isHidden = style != .gradient
        colorRow.isHidden = style != .solid
        imageRow.isHidden = style != .image
        for case let swatch as GradientSwatch in gradientRow.arrangedSubviews {
            swatch.isSelected = swatch.index == Preferences.backdropGradient
        }
        imageName.stringValue = Preferences.backdropImagePath.map { ($0 as NSString).lastPathComponent } ?? "未選択"
    }

    @objc private func modeChanged() {
        let style = Self.styles[max(0, modes.selectedSegment)]
        if let style {
            Preferences.backdropStyle = style
            canvas.background = true
            if style == .image, (Preferences.backdropImagePath ?? "").isEmpty { chooseImage() }
        } else {
            canvas.background = false
        }
        sync()
    }

    @objc private func colorChanged() {
        Preferences.backdropColor = colorWell.color
    }

    @objc private func paddingChanged(_ sender: NSSlider) {
        Preferences.backdropPadding = Int(sender.doubleValue.rounded())
    }

    @objc private func chooseImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.canChooseDirectories = false
        panel.message = "背景にする画像を選んでください"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Preferences.backdropImagePath = url.path
        Preferences.backdropStyle = .image
        canvas.background = true
        sync()
    }
}

/// A round preview of one of `Backdrop.gradients`.
private final class GradientSwatch: NSView {
    let index: Int
    var isSelected = false { didSet { needsDisplay = true } }
    private let handler: () -> Void

    init(index: Int, handler: @escaping () -> Void) {
        self.index = index
        self.handler = handler
        super.init(frame: .zero)
        widthAnchor.constraint(equalToConstant: 26).isActive = true
        heightAnchor.constraint(equalToConstant: 26).isActive = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        let circle = NSBezierPath(ovalIn: bounds.insetBy(dx: 3, dy: 3))
        NSGraphicsContext.saveGraphicsState()
        circle.addClip()
        Backdrop.drawGradient(index, in: bounds)
        NSGraphicsContext.restoreGraphicsState()
        if isSelected {
            NSColor.controlAccentColor.setStroke()
            let ring = NSBezierPath(ovalIn: bounds.insetBy(dx: 1, dy: 1))
            ring.lineWidth = 2
            ring.stroke()
        }
    }

    override func mouseDown(with event: NSEvent) { handler() }
}
