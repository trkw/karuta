import AppKit
import ServiceManagement

/// CleanShot-style settings: a sidebar of pages with colored icons, and grouped rounded rows on the right.
/// Created on demand and released when closed.
@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    var onClose: (() -> Void)?
    /// Called while a shortcut field is recording, so global hot keys don't swallow the key press.
    var onRecordingShortcut: ((Bool) -> Void)?

    private let pageHost = PageHostController()

    init() {
        let window = SettingsWindow(
            contentRect: NSRect(x: 0, y: 0, width: 780, height: 560),
            styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        window.title = "Karuta 設定"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self

        let sidebar = SidebarController()
        sidebar.onSelect = { [weak self] page in self?.show(page) }
        pageHost.onRecordingShortcut = { [weak self] recording in self?.onRecordingShortcut?(recording) }

        let split = NSSplitViewController()
        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebar)
        sidebarItem.canCollapse = false
        sidebarItem.minimumThickness = 210
        sidebarItem.maximumThickness = 210
        split.addSplitViewItem(sidebarItem)
        split.addSplitViewItem(NSSplitViewItem(viewController: pageHost))
        window.contentViewController = split
        window.setContentSize(NSSize(width: 780, height: 560))
        window.center()
        show(.general)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func windowWillClose(_ notification: Notification) {
        // A shortcut field may still be recording (hot keys paused); always bring them back.
        onRecordingShortcut?(false)
        onClose?()
    }

    private func show(_ page: SettingsPage) {
        pageHost.show(page)
    }
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

// MARK: - Pages

enum SettingsPage: CaseIterable {
    case general, shortcuts, quickAccess, screenshots, about

    var title: String {
        switch self {
        case .general: "一般"
        case .shortcuts: "ショートカット"
        case .quickAccess: "クイックアクセス"
        case .screenshots: "スクリーンショット"
        case .about: "Karuta について"
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape.fill"
        case .shortcuts: "command"
        case .quickAccess: "rectangle.stack.fill"
        case .screenshots: "camera.fill"
        case .about: "info"
        }
    }

    var tint: NSColor {
        switch self {
        case .general, .shortcuts, .about: .systemGray
        case .quickAccess: .systemGreen
        case .screenshots: .systemBlue
        }
    }
}

// MARK: - Sidebar

private final class SidebarController: NSViewController {
    var onSelect: ((SettingsPage) -> Void)?
    private var rows: [SidebarRow] = []

    override func loadView() {
        rows = SettingsPage.allCases.map { page in
            SidebarRow(page: page) { [weak self] in self?.select(page) }
        }
        let top = NSStackView(views: rows.filter { $0.page != .about })
        top.orientation = .vertical
        top.spacing = 2
        top.alignment = .leading

        let view = NSView()
        top.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(top)
        let about = rows[rows.count - 1] // .about is the last case
        about.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(about)
        NSLayoutConstraint.activate([
            top.topAnchor.constraint(equalTo: view.topAnchor, constant: 52),
            top.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 10),
            top.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -10),
            about.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 10),
            about.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -10),
            about.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -12),
        ])
        for row in rows where row.page != .about {
            row.widthAnchor.constraint(equalTo: top.widthAnchor).isActive = true
        }
        self.view = view
        select(.general)
    }

    private func select(_ page: SettingsPage) {
        rows.forEach { $0.isSelected = $0.page == page }
        onSelect?(page)
    }
}

private final class SidebarRow: NSView {
    let page: SettingsPage
    var isSelected = false { didSet { needsDisplay = true } }
    private let handler: () -> Void

    init(page: SettingsPage, handler: @escaping () -> Void) {
        self.page = page
        self.handler = handler
        super.init(frame: .zero)
        heightAnchor.constraint(equalToConstant: 32).isActive = true

        let icon = NSImageView(image: Self.tile(symbol: page.symbol, tint: page.tint))
        let label = NSTextField(labelWithString: page.title)
        label.font = .systemFont(ofSize: 13)
        let stack = NSStackView(views: [icon, label])
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 22),
            icon.heightAnchor.constraint(equalToConstant: 22),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        guard isSelected else { return }
        NSColor.labelColor.withAlphaComponent(0.1).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 7, yRadius: 7).fill()
    }

    override func mouseDown(with event: NSEvent) {
        handler()
    }

    /// A colored rounded square with a white symbol, like System Settings.
    private static func tile(symbol: String, tint: NSColor) -> NSImage {
        NSImage(size: NSSize(width: 22, height: 22), flipped: false) { rect in
            let gradient = NSGradient(starting: tint.blended(withFraction: 0.25, of: .white) ?? tint, ending: tint)
            gradient?.draw(in: NSBezierPath(roundedRect: rect, xRadius: 5.5, yRadius: 5.5), angle: -90)
            if let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 11, weight: .semibold)) {
                let white = NSImage(size: image.size, flipped: false) { r in
                    image.draw(in: r)
                    NSColor.white.set()
                    r.fill(using: .sourceAtop)
                    return true
                }
                white.draw(in: NSRect(x: rect.midX - image.size.width / 2, y: rect.midY - image.size.height / 2,
                                      width: image.size.width, height: image.size.height))
            }
            return true
        }
    }
}

// MARK: - Page content

private final class PageHostController: NSViewController {
    var onRecordingShortcut: ((Bool) -> Void)?
    private let scrollView = NSScrollView()

    override func loadView() {
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        view = scrollView
    }

    func show(_ page: SettingsPage) {
        loadViewIfNeeded()
        let builder = PageBuilder(onRecordingShortcut: { [weak self] in self?.onRecordingShortcut?($0) })
        let content = builder.build(page)
        scrollView.documentView = content
        content.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
            content.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            content.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),
        ])
    }
}

@MainActor
private struct PageBuilder {
    let onRecordingShortcut: (Bool) -> Void

    func build(_ page: SettingsPage) -> NSView {
        let title = label(page.title, size: 17, weight: .bold)
        var views: [NSView] = [title]
        switch page {
        case .general: views += general()
        case .shortcuts: views += shortcuts()
        case .quickAccess: views += quickAccess()
        case .screenshots: views += screenshots()
        case .about: views += about()
        }

        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 24
        stack.setCustomSpacing(20, after: title)
        stack.edgeInsets = NSEdgeInsets(top: 18, left: 24, bottom: 28, right: 24)
        for view in views where view !== title {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -48).isActive = true
        }
        let document = FlippedView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: document.topAnchor),
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: document.bottomAnchor),
        ])
        return document
    }

    // MARK: Pages

    private func general() -> [NSView] {
        [
            section("アプリ", rows: [
                switchRow("ログイン時に起動", SMAppService.mainApp.status == .enabled) { on in
                    do {
                        if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                    } catch {
                        NSLog("Karuta: login item toggle failed: \(error)")
                    }
                },
                switchRow("メニューバーにアイコンを表示", Preferences.showMenuBarIcon,
                          note: "隠したときは、Karuta をもう一度開くとこの画面が出ます。") { Preferences.showMenuBarIcon = $0 },
            ]),
            section("撮影", rows: [
                switchRow("撮影するときデスクトップのアイコンを隠す", Preferences.hideDesktopIcons,
                          note: "壁紙はそのまま、アイコンだけが写らなくなります。") { Preferences.hideDesktopIcons = $0 },
            ]),
            section("サウンド", rows: [
                switchRow("サウンドを鳴らす", Preferences.playSound) { Preferences.playSound = $0 },
                row("シャッター音", control: soundPicker()),
            ]),
            section("書き出し", rows: [
                row("保存先", control: folderControl()),
                noteRow("クイックアクセスの「保存」や、撮影後の保存で使う場所です。"),
            ]),
            afterCapture(),
        ]
    }

    private func shortcuts() -> [NSView] {
        ShortcutAction.Group.allCases.map { group in
            var rows = ShortcutAction.allCases.filter { $0.group == group }.map { action -> NSView in
                let field = ShortcutField(shortcut: Preferences.shortcut(for: action))
                field.onChange = { Preferences.setShortcut($0, for: action) }
                field.onRecording = onRecordingShortcut
                return row(action.title, control: field)
            }
            switch group {
            case .screenshots:
                rows.append(noteRow("欄をクリックして新しいキーを押します。Delete で解除、Esc で取り消し。⌘⇧3 / 4 / 5 を使うときは、"
                    + "macOS の「キーボードショートカット」>「スクリーンショット」をオフにしてください。"
                    + "「範囲を撮影して〜」は撮影後の動作の設定を使わず、その動作だけを行います。"))
            case .general, .overlay:
                break
            }
            return section(group.rawValue, rows: rows)
        }
    }

    private func quickAccess() -> [NSView] {
        let choices: [(String, Int)] = [("閉じない", 0), ("5 秒", 5), ("10 秒", 10), ("30 秒", 30), ("1 分", 60)]
        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        popup.addItems(withTitles: choices.map(\.0))
        popup.selectItem(at: choices.firstIndex { $0.1 == Preferences.autoCloseSeconds } ?? 0)
        let target = ClosureTarget { sender in
            guard let popup = sender as? NSPopUpButton else { return }
            Preferences.autoCloseSeconds = choices[popup.indexOfSelectedItem].1
        }
        target.attach(to: popup)
        return [
            section("オーバーレイ", rows: [
                switchRow("撮影後にサムネイルを表示", Preferences.showOverlay) { Preferences.showOverlay = $0 },
                row("自動で閉じる", control: popup),
                noteRow("カーソルを乗せている間は閉じません。"),
            ]),
        ]
    }

    private func screenshots() -> [NSView] {
        let formats = Preferences.ImageFormat.allCases
        let format = NSSegmentedControl(labels: formats.map(\.title), trackingMode: .selectOne, target: nil, action: nil)
        format.selectedSegment = formats.firstIndex(of: Preferences.format) ?? 0
        ClosureTarget { sender in
            guard let control = sender as? NSSegmentedControl else { return }
            Preferences.format = formats[control.selectedSegment]
        }.attach(to: format)
        let fileName = NSTextField(string: Preferences.fileNameTemplate)
        fileName.placeholderString = Preferences.defaultFileNameTemplate
        fileName.cell?.sendsActionOnEndEditing = true
        fileName.widthAnchor.constraint(equalToConstant: 220).isActive = true
        ClosureTarget { sender in
            guard let field = sender as? NSTextField else { return }
            Preferences.fileNameTemplate = field.stringValue
        }.attach(to: fileName)
        let backdrop = NSPopUpButton(frame: .zero, pullsDown: false)
        backdrop.addItems(withTitles: Preferences.AutoBackdrop.allCases.map(\.title))
        backdrop.selectItem(at: Preferences.AutoBackdrop.allCases.firstIndex(of: Preferences.autoBackdrop) ?? 0)
        ClosureTarget { sender in
            guard let popup = sender as? NSPopUpButton else { return }
            Preferences.autoBackdrop = Preferences.AutoBackdrop.allCases[popup.indexOfSelectedItem]
        }.attach(to: backdrop)
        let timerChoices = [3, 5, 10]
        let timer = NSPopUpButton(frame: .zero, pullsDown: false)
        timer.addItems(withTitles: timerChoices.map { "\($0) 秒" })
        timer.selectItem(at: timerChoices.firstIndex(of: Preferences.selfTimerSeconds) ?? 1)
        ClosureTarget { sender in
            guard let popup = sender as? NSPopUpButton else { return }
            Preferences.selfTimerSeconds = timerChoices[popup.indexOfSelectedItem]
        }.attach(to: timer)
        return [
            section("ファイル", rows: [
                row("形式", control: format),
                row("ファイル名", control: fileName),
                noteRow("{date} は日付、{time} は時刻、{app} は手前にあったアプリの名前になります。"),
                switchRow("Retina を 1x に縮小", Preferences.scaleRetina,
                          note: "コピーと保存の画像を半分のピクセル数にします（見た目の大きさは同じ）。") { Preferences.scaleRetina = $0 },
            ]),
            section("撮影", rows: [
                switchRow("マウスカーソルを写す", Preferences.showCursor,
                          note: "画面を止めて選ぶときは、止めた瞬間の位置のカーソルが写ります。") { Preferences.showCursor = $0 },
            ]),
            section("背景", rows: [
                row("撮影後に背景を付ける", control: backdrop),
                noteRow("背景の種類と余白は、注釈エディタの背景ボタンで選んだものを使います。"),
            ]),
            section("範囲選択", rows: [
                switchRow("画面を止めて選ぶ", Preferences.freezeScreen,
                          note: "動画やメニューが動いていても、選び始めた瞬間の画面を撮ります。") { Preferences.freezeScreen = $0 },
                switchRow("拡大鏡を表示", Preferences.showLoupe,
                          note: "画面を止めているときに使えます。") { Preferences.showLoupe = $0 },
            ]),
            section("セルフタイマー", rows: [
                row("撮るまでの時間", control: timer),
                noteRow("範囲を選んでから撮るまで待ちます。メニューを開いた状態などを撮るときに使います。"),
            ]),
        ]
    }

    private func about() -> [NSView] {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "-"
        let icon = NSImageView(image: NSApp.applicationIconImage)
        icon.widthAnchor.constraint(equalToConstant: 64).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 64).isActive = true
        let name = label("Karuta", size: 15, weight: .semibold)
        let detail = label("バージョン \(version)", size: 12, weight: .regular, color: .secondaryLabelColor)
        let link = NSButton(title: "GitHub で見る", target: nil, action: nil)
        link.bezelStyle = .rounded
        ClosureTarget { _ in
            if let url = URL(string: "https://github.com/trkw/karuta") { NSWorkspace.shared.open(url) }
        }.attach(to: link)
        let stack = NSStackView(views: [icon, name, detail, link])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 6
        stack.setCustomSpacing(14, after: detail)
        return [stack]
    }

    /// Action × Screenshot table, like CleanShot (recording joins as a column once it exists).
    private func afterCapture() -> NSView {
        let heading = label("撮影後", size: 13, weight: .bold)
        let caption = label("撮影したあとに何をするかを選びます。", size: 12, weight: .regular, color: .secondaryLabelColor)
        let header = row("動作", control: label("スクリーンショット", size: 12, weight: .medium, color: .secondaryLabelColor),
                         titleColor: .secondaryLabelColor)
        let rows: [NSView] = [
            header,
            checkRow("クイックアクセスを表示", Preferences.showOverlay) { Preferences.showOverlay = $0 },
            checkRow("クリップボードにコピー", Preferences.copyToClipboard) { Preferences.copyToClipboard = $0 },
            checkRow("保存", Preferences.saveToFile) { Preferences.saveToFile = $0 },
            checkRow("注釈エディタを開く", Preferences.openEditor) { Preferences.openEditor = $0 },
        ]
        let group = groupBox(rows)
        let stack = NSStackView(views: [heading, caption, group])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        stack.setCustomSpacing(10, after: caption)
        heading.leadingAnchor.constraint(equalTo: stack.leadingAnchor, constant: 12).isActive = true
        caption.leadingAnchor.constraint(equalTo: stack.leadingAnchor, constant: 12).isActive = true
        group.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        return stack
    }

    // MARK: Building blocks

    private func label(_ text: String, size: CGFloat, weight: NSFont.Weight,
                       color: NSColor = .labelColor) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = .systemFont(ofSize: size, weight: weight)
        field.textColor = color
        return field
    }

    private func section(_ heading: String, rows: [NSView]) -> NSView {
        let title = label(heading, size: 13, weight: .bold)
        let group = groupBox(rows)
        let stack = NSStackView(views: [title, group])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        title.leadingAnchor.constraint(equalTo: stack.leadingAnchor, constant: 12).isActive = true
        group.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        return stack
    }

    private func groupBox(_ rows: [NSView]) -> NSView {
        let box = GroupBox()
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        for (index, row) in rows.enumerated() {
            if index > 0 { stack.addArrangedSubview(Hairline()) }
            stack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        box.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: box.topAnchor),
            stack.bottomAnchor.constraint(equalTo: box.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -12),
        ])
        return box
    }

    private func row(_ title: String, note: String? = nil, control: NSView,
                     titleColor: NSColor = .labelColor) -> NSView {
        let titleLabel = label(title, size: 13, weight: .regular, color: titleColor)
        var texts: [NSView] = [titleLabel]
        if let note {
            let noteLabel = label(note, size: 11, weight: .regular, color: .secondaryLabelColor)
            noteLabel.lineBreakMode = .byWordWrapping
            noteLabel.maximumNumberOfLines = 0
            noteLabel.preferredMaxLayoutWidth = 380
            texts.append(noteLabel)
        }
        let textStack = NSStackView(views: texts)
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 2
        textStack.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        control.setContentHuggingPriority(.required, for: .horizontal)

        let row = NSStackView(views: [textStack, NSView(), control])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.edgeInsets = NSEdgeInsets(top: 10, left: 0, bottom: 10, right: 0)
        row.heightAnchor.constraint(greaterThanOrEqualToConstant: 40).isActive = true
        return row
    }

    private func switchRow(_ title: String, _ isOn: Bool, note: String? = nil,
                           onChange: @escaping (Bool) -> Void) -> NSView {
        let toggle = NSSwitch()
        toggle.state = isOn ? .on : .off
        toggle.controlSize = .small
        ClosureTarget { sender in onChange((sender as? NSSwitch)?.state == .on) }.attach(to: toggle)
        return row(title, note: note, control: toggle)
    }

    private func checkRow(_ title: String, _ isOn: Bool, onChange: @escaping (Bool) -> Void) -> NSView {
        let check = NSButton(checkboxWithTitle: "", target: nil, action: nil)
        check.state = isOn ? .on : .off
        ClosureTarget { sender in onChange((sender as? NSButton)?.state == .on) }.attach(to: check)
        // Center the box under the column header.
        let holder = NSView()
        check.translatesAutoresizingMaskIntoConstraints = false
        holder.addSubview(check)
        NSLayoutConstraint.activate([
            holder.widthAnchor.constraint(equalToConstant: 110),
            holder.heightAnchor.constraint(equalTo: check.heightAnchor),
            check.centerXAnchor.constraint(equalTo: holder.centerXAnchor),
            check.centerYAnchor.constraint(equalTo: holder.centerYAnchor),
        ])
        return row(title, control: holder)
    }

    private func noteRow(_ text: String) -> NSView {
        let note = label(text, size: 11, weight: .regular, color: .secondaryLabelColor)
        note.lineBreakMode = .byWordWrapping
        note.maximumNumberOfLines = 0
        note.preferredMaxLayoutWidth = 480
        let row = NSStackView(views: [note])
        row.edgeInsets = NSEdgeInsets(top: 10, left: 0, bottom: 12, right: 0)
        return row
    }

    private func soundPicker() -> NSView {
        let names = ["", "Pop", "Tink", "Glass", "Purr", "Bottle", "Morse", "Frog"]
        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        popup.addItems(withTitles: names.map { $0.isEmpty ? "システム標準" : $0 })
        popup.selectItem(at: names.firstIndex(of: Preferences.shutterSound) ?? 0)
        ClosureTarget { sender in
            guard let popup = sender as? NSPopUpButton else { return }
            Preferences.shutterSound = names[popup.indexOfSelectedItem]
            Sounds.shutter()?.play()
        }.attach(to: popup)
        return popup
    }

    private func folderControl() -> NSView {
        let name = label(FileManager.default.displayName(atPath: Preferences.saveDirectory.path),
                         size: 13, weight: .regular, color: .secondaryLabelColor)
        let icon = NSImageView(image: NSWorkspace.shared.icon(forFile: Preferences.saveDirectory.path))
        icon.widthAnchor.constraint(equalToConstant: 16).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 16).isActive = true
        let choose = NSButton(title: "選択…", target: nil, action: nil)
        choose.bezelStyle = .rounded
        choose.controlSize = .small
        ClosureTarget { sender in
            let panel = NSOpenPanel()
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.canCreateDirectories = true
            panel.directoryURL = Preferences.saveDirectory
            panel.prompt = "選択"
            let apply: (NSApplication.ModalResponse) -> Void = { response in
                guard response == .OK, let url = panel.url else { return }
                Preferences.saveDirectory = url
                name.stringValue = FileManager.default.displayName(atPath: url.path)
                icon.image = NSWorkspace.shared.icon(forFile: url.path)
            }
            if let window = (sender as? NSView)?.window {
                panel.beginSheetModal(for: window, completionHandler: apply)
            } else {
                apply(panel.runModal())
            }
        }.attach(to: choose)
        let stack = NSStackView(views: [icon, name, choose])
        stack.spacing = 6
        stack.setCustomSpacing(12, after: name)
        return stack
    }
}

// MARK: - Controls

/// Keeps a closure alive as a control's target (retained by the control via an associated object).
private final class ClosureTarget: NSObject {
    private static var key = 0
    private let handler: (Any?) -> Void

    init(_ handler: @escaping (Any?) -> Void) {
        self.handler = handler
    }

    func attach(to control: NSControl) {
        control.target = self
        control.action = #selector(fire(_:))
        objc_setAssociatedObject(control, &Self.key, self, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }

    @objc private func fire(_ sender: Any?) { handler(sender) }
}

private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

private final class GroupBox: NSView {
    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.cornerCurve = .continuous
        translatesAutoresizingMaskIntoConstraints = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.05).cgColor
        layer?.borderColor = NSColor.labelColor.withAlphaComponent(0.06).cgColor
        layer?.borderWidth = 1
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
        layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.08).cgColor
    }
}

/// Click, then press the new key combination. Esc cancels, Delete clears.
private final class ShortcutField: NSButton {
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
        super.init(frame: .zero)
        bezelStyle = .rounded
        setButtonType(.momentaryPushIn)
        target = self
        action = #selector(toggleRecording)
        widthAnchor.constraint(greaterThanOrEqualToConstant: 110).isActive = true
        refresh()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }

    @objc private func toggleRecording() {
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
        contentTintColor = recording ? .controlAccentColor : nil
    }
}

// MARK: - Sounds

enum Sounds {
    /// The shutter sound chosen in Settings (the system screenshot sound by default).
    @MainActor static func shutter() -> NSSound? {
        let name = Preferences.shutterSound
        if !name.isEmpty, let sound = NSSound(named: NSSound.Name(name)) { return sound }
        let system = "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/system/Screen Capture.aif"
        return NSSound(contentsOfFile: system, byReference: true) ?? NSSound(named: "Tink")
    }
}
