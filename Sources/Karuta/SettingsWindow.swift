import AppKit
import ServiceManagement

/// A single, calm settings page: a pale-blue backdrop with rounded white cards, short labels and switches.
/// Created on demand and released when closed.
@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    var onClose: (() -> Void)?
    /// Called while a shortcut field is recording, so global hot keys don't swallow the key press.
    var onRecordingShortcut: ((Bool) -> Void)?

    private var folderButton: NSButton?

    init() {
        let window = SettingsWindow(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 600),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        window.title = "Karuta 設定"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.backgroundColor = Palette.backdrop
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        // The page scrolls when the screen is too short to show it whole.
        let content = makeContent()
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.documentView = content
        content.translatesAutoresizingMaskIntoConstraints = false
        content.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor).isActive = true
        content.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor).isActive = true
        window.contentView = scrollView

        let fitting = content.fittingSize
        let available = (NSScreen.main?.visibleFrame.height ?? fitting.height) - 40
        window.setContentSize(NSSize(width: fitting.width, height: min(fitting.height, available)))
        window.center()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func windowWillClose(_ notification: Notification) {
        // A shortcut field may still be recording (hot keys paused); always bring them back.
        onRecordingShortcut?(false)
        onClose?()
    }

    // MARK: - Layout

    private func makeContent() -> NSView {
        let title = NSTextField(labelWithString: "設定")
        title.font = .systemFont(ofSize: 22, weight: .bold)
        title.textColor = Palette.ink

        let stack = NSStackView(views: [
            title,
            section("撮影したら", rows: [
                switchRow("プレビューを表示", Preferences.showOverlay) { Preferences.showOverlay = $0 },
                switchRow("クリップボードにコピー", Preferences.copyToClipboard) { Preferences.copyToClipboard = $0 },
                switchRow("ファイルに保存", Preferences.saveToFile) { Preferences.saveToFile = $0 },
            ]),
            section("撮影", rows: [
                switchRow("画面を止めて範囲を選ぶ", Preferences.freezeScreen) { Preferences.freezeScreen = $0 },
                switchRow("シャッター音", Preferences.playSound) { Preferences.playSound = $0 },
            ]),
            section("保存", rows: [row("保存先", control: makeFolderButton()), row("形式", control: makeFormatPicker())]),
            section("ショートカット", rows: ShortcutAction.allCases.map { action in
                row(action.title, control: makeShortcutField(for: action))
            }),
            section("一般", rows: [
                switchRow("ログイン時に起動", SMAppService.mainApp.status == .enabled) { on in
                    do {
                        if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                    } catch {
                        NSLog("Karuta: login item toggle failed: \(error)")
                    }
                },
            ]),
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 18
        stack.setCustomSpacing(14, after: title)
        stack.edgeInsets = NSEdgeInsets(top: 44, left: 24, bottom: 24, right: 24)
        stack.translatesAutoresizingMaskIntoConstraints = false
        for view in stack.arrangedSubviews where view !== title {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -48).isActive = true
        }

        let content = FlippedView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            content.widthAnchor.constraint(equalToConstant: 440),
        ])
        return content
    }

    /// A small heading above a rounded card that holds the rows, separated by hairlines.
    private func section(_ heading: String, rows: [NSView]) -> NSView {
        let label = NSTextField(labelWithString: heading)
        label.font = .systemFont(ofSize: 12, weight: .semibold)
        label.textColor = Palette.subtleInk

        let card = CardView()
        let rowStack = NSStackView()
        rowStack.orientation = .vertical
        rowStack.spacing = 0
        rowStack.translatesAutoresizingMaskIntoConstraints = false
        for (index, row) in rows.enumerated() {
            if index > 0 { rowStack.addArrangedSubview(Hairline()) }
            rowStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: rowStack.widthAnchor).isActive = true
        }
        card.addSubview(rowStack)
        NSLayoutConstraint.activate([
            rowStack.topAnchor.constraint(equalTo: card.topAnchor, constant: 4),
            rowStack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -4),
            rowStack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 16),
            rowStack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -12),
        ])

        let stack = NSStackView(views: [label, card])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        label.leadingAnchor.constraint(equalTo: stack.leadingAnchor, constant: 6).isActive = true
        card.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        return stack
    }

    private func row(_ title: String, control: NSView) -> NSView {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 13)
        label.textColor = Palette.ink
        label.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        let row = NSStackView(views: [label, NSView(), control])
        row.orientation = .horizontal
        row.distribution = .fill
        row.alignment = .centerY
        row.heightAnchor.constraint(equalToConstant: 40).isActive = true
        return row
    }

    private func switchRow(_ title: String, _ isOn: Bool, onChange: @escaping (Bool) -> Void) -> NSView {
        let toggle = ClosureSwitch(onChange: onChange)
        toggle.state = isOn ? .on : .off
        toggle.controlSize = .small
        return row(title, control: toggle)
    }

    private func makeFolderButton() -> NSView {
        let button = PillControl(title: Self.folderName(Preferences.saveDirectory)) { [weak self] in self?.chooseFolder() }
        button.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
        button.imagePosition = .imageLeading
        folderButton = button
        return button
    }

    private func makeFormatPicker() -> NSView {
        let picker = NSSegmentedControl(labels: ["PNG", "JPEG"], trackingMode: .selectOne,
                                        target: self, action: #selector(formatChanged(_:)))
        picker.selectedSegment = Preferences.format == .png ? 0 : 1
        picker.controlSize = .small
        return picker
    }

    private func makeShortcutField(for action: ShortcutAction) -> NSView {
        let field = ShortcutField(shortcut: Preferences.shortcut(for: action))
        field.onChange = { Preferences.setShortcut($0, for: action) }
        field.onRecording = { [weak self] recording in self?.onRecordingShortcut?(recording) }
        return field
    }

    // MARK: - Actions

    @objc private func formatChanged(_ sender: NSSegmentedControl) {
        Preferences.format = sender.selectedSegment == 0 ? .png : .jpeg
    }

    private func chooseFolder() {
        guard let window else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = Preferences.saveDirectory
        panel.prompt = "選択"
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            Preferences.saveDirectory = url
            self?.folderButton?.title = Self.folderName(url)
        }
    }

    private static func folderName(_ url: URL) -> String {
        FileManager.default.displayName(atPath: url.path)
    }
}

/// Top-aligned document view for the scroll view.
private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// There is no main menu, so ⌘W is handled here.
private final class SettingsWindow: NSWindow {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
           event.charactersIgnoringModifiers == "w" {
            performClose(nil)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

// MARK: - Palette

/// Soft, airy colors in the spirit of Nani: an icy-blue backdrop with white cards (deep navy in dark mode).
enum Palette {
    static let backdrop = dynamic(light: NSColor(srgbRed: 0.925, green: 0.965, blue: 1, alpha: 1), // #ECF6FF
                                  dark: NSColor(srgbRed: 0.075, green: 0.094, blue: 0.125, alpha: 1))
    static let card = dynamic(light: .white, dark: NSColor(srgbRed: 0.125, green: 0.149, blue: 0.192, alpha: 1))
    static let cardBorder = dynamic(light: NSColor(srgbRed: 0.82, green: 0.89, blue: 0.97, alpha: 1),
                                    dark: NSColor(white: 1, alpha: 0.08))
    static let hairline = dynamic(light: NSColor(srgbRed: 0.9, green: 0.94, blue: 0.98, alpha: 1),
                                  dark: NSColor(white: 1, alpha: 0.06))
    static let ink = dynamic(light: NSColor(srgbRed: 0.11, green: 0.16, blue: 0.24, alpha: 1),
                             dark: NSColor(white: 0.93, alpha: 1))
    static let subtleInk = dynamic(light: NSColor(srgbRed: 0.42, green: 0.5, blue: 0.62, alpha: 1),
                                   dark: NSColor(white: 0.6, alpha: 1))
    static let pill = dynamic(light: NSColor(srgbRed: 0.925, green: 0.965, blue: 1, alpha: 1),
                              dark: NSColor(white: 1, alpha: 0.08))

    private static func dynamic(light: NSColor, dark: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        }
    }
}

// MARK: - Controls

private final class CardView: NSView {
    init() {
        super.init(frame: .zero)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        layer?.cornerRadius = 14
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 1
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = Palette.card.cgColor
        layer?.borderColor = Palette.cardBorder.cgColor
    }
}

private final class Hairline: NSView {
    init() {
        super.init(frame: .zero)
        wantsLayer = true
        heightAnchor.constraint(equalToConstant: 1).isActive = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = Palette.hairline.cgColor
    }
}

private final class ClosureSwitch: NSSwitch {
    private let onChange: (Bool) -> Void

    init(onChange: @escaping (Bool) -> Void) {
        self.onChange = onChange
        super.init(frame: .zero)
        target = self
        action = #selector(changed)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    @objc private func changed() { onChange(state == .on) }
}

/// A soft rounded button used for values (folder, shortcut).
private class PillControl: NSButton {
    private let handler: () -> Void

    init(title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(frame: .zero)
        self.title = title
        isBordered = false
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.cornerCurve = .continuous
        font = .systemFont(ofSize: 12, weight: .medium)
        contentTintColor = Palette.ink
        target = self
        action = #selector(clicked)
        heightAnchor.constraint(equalToConstant: 26).isActive = true
        setContentHuggingPriority(.required, for: .horizontal)
        updateBackground()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize {
        let size = super.intrinsicContentSize
        return NSSize(width: max(size.width + 24, 72), height: 26)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateBackground()
    }

    private func updateBackground() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = Palette.pill.cgColor
        }
    }

    @objc private func clicked() { handler() }
}

/// Click, then press the new key combination. Esc cancels, Delete clears.
private final class ShortcutField: PillControl {
    var onChange: ((Shortcut?) -> Void)?
    var onRecording: ((Bool) -> Void)?

    private var shortcut: Shortcut?
    private var recording = false {
        didSet {
            guard recording != oldValue else { return }
            onRecording?(recording)
            refresh()
        }
    }

    init(shortcut: Shortcut?) {
        self.shortcut = shortcut
        weak var weakSelf: ShortcutField?
        super.init(title: "") { weakSelf?.toggleRecording() }
        weakSelf = self
        refresh()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }

    private func toggleRecording() {
        recording.toggle()
        if recording { window?.makeFirstResponder(self) }
    }

    override func resignFirstResponder() -> Bool {
        recording = false
        return super.resignFirstResponder()
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard recording else { return super.performKeyEquivalent(with: event) }
        keyDown(with: event)
        return true
    }

    override func keyDown(with event: NSEvent) {
        guard recording else { return super.keyDown(with: event) }
        switch Int(event.keyCode) {
        case 53: // Esc
            recording = false
        case 51, 117: // Delete
            shortcut = nil
            onChange?(nil)
            recording = false
        default:
            guard let new = Shortcut(event: event) else {
                NSSound.beep()
                return
            }
            shortcut = new
            onChange?(new)
            recording = false
        }
    }

    private func refresh() {
        title = recording ? "キーを押す…" : (shortcut?.displayString ?? "なし")
        contentTintColor = recording ? .controlAccentColor : Palette.ink
        invalidateIntrinsicContentSize()
    }
}
