import AppKit

/// The self-timer's countdown: a small dark square with the remaining seconds, centred on what will be
/// captured. It never takes focus (so an open menu stays open); clicking it cancels the shot.
@MainActor
enum SelfTimer {
    /// Counts down `seconds` over `rect` (AppKit global coordinates). Returns false when cancelled.
    static func countdown(_ seconds: Int, over rect: NSRect) async -> Bool {
        let panel = CountdownPanel(center: NSPoint(x: rect.midX, y: rect.midY))
        panel.orderFrontRegardless()
        defer { panel.orderOut(nil) }
        for remaining in stride(from: seconds, to: 0, by: -1) {
            panel.show(remaining)
            if remaining <= 3 { NSSound(named: "Tink")?.play() }
            try? await Task.sleep(for: .seconds(1))
            if panel.isCancelled { return false }
        }
        return true
    }
}

private final class CountdownPanel: NSPanel {
    private(set) var isCancelled = false
    private let label = NSTextField(labelWithString: "")

    init(center: NSPoint) {
        let size = NSSize(width: 96, height: 96)
        super.init(contentRect: NSRect(x: center.x - size.width / 2, y: center.y - size.height / 2,
                                       width: size.width, height: size.height),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = .screenSaver
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let view = ClickView(frame: NSRect(origin: .zero, size: size)) { [weak self] in self?.isCancelled = true }
        view.wantsLayer = true
        view.layer?.cornerRadius = 20
        view.layer?.backgroundColor = NSColor(white: 0.1, alpha: 0.8).cgColor
        view.toolTip = "クリックで中止"
        label.font = .monospacedDigitSystemFont(ofSize: 48, weight: .semibold)
        label.textColor = .white
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])
        contentView = view
    }

    func show(_ remaining: Int) {
        label.stringValue = "\(remaining)"
    }
}

private final class ClickView: NSView {
    private let onClick: () -> Void

    init(frame: NSRect, onClick: @escaping () -> Void) {
        self.onClick = onClick
        super.init(frame: frame)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { onClick() }
}
