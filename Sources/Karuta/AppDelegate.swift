import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    enum CaptureMode {
        case area, window, fullscreen, previousArea
    }

    private var statusItem: NSStatusItem?
    private let selection = SelectionController()
    private let overlay = QuickOverlay()
    private var editors: [EditorWindowController] = []
    private var pins: [PinWindow] = []
    /// The last area selection, relative to its display's origin (so it survives display rearrangement),
    /// for "前回の範囲を撮影".
    private var lastArea: (rect: CGRect, displayID: CGDirectDisplayID)?
    private var isCapturing = false
    private var settings: SettingsWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        setUpStatusItem()
        registerHotKeys()
        NotificationCenter.default.addObserver(forName: Preferences.didChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.registerHotKeys()
                self?.rebuildMenu()
                self?.statusItem?.isVisible = Preferences.showMenuBarIcon
            }
        }
        overlay.onEdit = { [weak self] shot in self?.openEditor(shot) }
        overlay.onPin = { [weak self] shot, frame in self?.pin(shot, near: frame) }
        if !CGPreflightScreenCaptureAccess() {
            CGRequestScreenCaptureAccess()
        }
    }

    /// Opening Karuta again (e.g. from Finder) shows Settings: the way back when the menu bar icon is hidden.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openSettings()
        return false
    }

    // MARK: - Setup

    private func setUpStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = Self.menuBarImage()

        statusItem = item
        item.isVisible = Preferences.showMenuBarIcon
        rebuildMenu()
    }

    private func rebuildMenu() {
        let menu = NSMenu()
        let actions: [(ShortcutAction, Selector)] = [
            (.area, #selector(captureArea)), (.window, #selector(captureWindow)),
            (.fullscreen, #selector(captureFullscreen)), (.previousArea, #selector(capturePreviousArea)),
        ]
        for (action, selector) in actions {
            let item = NSMenuItem(title: action.title, action: selector, keyEquivalent: "")
            item.target = self
            if let key = Preferences.shortcut(for: action)?.menuKeyEquivalent {
                item.keyEquivalent = key.key
                item.keyEquivalentModifierMask = key.mask
            }
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let settingsItem = NSMenuItem(title: "設定…", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Karuta を終了", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem?.menu = menu
    }

    /// メニューバー用のテンプレート画像（傾けた札と中央の点）。画像ファイルを持たずにコードで描く
    private static func menuBarImage() -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            let transform = NSAffineTransform()
            transform.translateX(by: 9, yBy: 9)
            transform.rotate(byDegrees: 8)
            transform.concat()
            NSColor.black.set()
            let card = NSBezierPath(roundedRect: NSRect(x: -4.5, y: -6, width: 9, height: 12), xRadius: 1.6, yRadius: 1.6)
            card.lineWidth = 1.5
            card.stroke()
            NSBezierPath(ovalIn: NSRect(x: -1.7, y: -1.7, width: 3.4, height: 3.4)).fill()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Karuta"
        return image
    }

    /// Shortcuts come from Settings (default ⌘⇧3 / ⌘⇧4 / ⌘⇧5 like CleanShot; turn off the macOS ones).
    private func registerHotKeys() {
        let hotKeys = HotKeyCenter.shared
        hotKeys.unregisterAll()
        let modes: [ShortcutAction: CaptureMode] = [
            .area: .area, .window: .window, .fullscreen: .fullscreen, .previousArea: .previousArea,
        ]
        for (action, mode) in modes {
            guard let shortcut = Preferences.shortcut(for: action) else { continue }
            hotKeys.register(keyCode: Int(shortcut.keyCode), modifiers: Int(shortcut.modifiers)) { [weak self] in
                self?.capture(mode)
            }
        }
    }

    // MARK: - Actions

    @objc private func captureArea() { capture(.area) }
    @objc private func captureWindow() { capture(.window) }
    @objc private func captureFullscreen() { capture(.fullscreen) }
    @objc private func capturePreviousArea() { capture(.previousArea) }

    @objc private func openSettings() {
        if settings == nil {
            let controller = SettingsWindowController()
            controller.onClose = { [weak self] in self?.settings = nil }
            controller.onRecordingShortcut = { [weak self] recording in
                // Pause global hot keys so the combination being recorded reaches the field.
                if recording { HotKeyCenter.shared.unregisterAll() } else { self?.registerHotKeys() }
            }
            settings = controller
        }
        NSApp.activate()
        settings?.showWindow(nil)
        settings?.window?.makeKeyAndOrderFront(nil)
    }

    // MARK: - Capture

    private func capture(_ mode: CaptureMode) {
        guard !isCapturing else { return }
        isCapturing = true
        Task {
            defer { self.isCapturing = false }
            do {
                let content = try await Capturer.shareableContent()
                let shot: Shot
                let screen: NSScreen
                switch mode {
                case .fullscreen:
                    screen = NSScreen.underMouse
                    shot = try await Capturer.captureDisplay(of: screen, rect: nil, content: content)
                case .previousArea:
                    guard let last = self.lastArea,
                          let lastScreen = NSScreen.screens.first(where: { $0.displayID == last.displayID })
                    else {
                        NSSound.beep()
                        return
                    }
                    let rect = last.rect.offsetBy(dx: lastScreen.frame.minX, dy: lastScreen.frame.minY)
                        .intersection(lastScreen.frame)
                    guard !rect.isEmpty else {
                        NSSound.beep()
                        return
                    }
                    screen = lastScreen
                    shot = try await Capturer.captureDisplay(of: screen, rect: rect, content: content)
                case .area, .window:
                    let candidates = Capturer.orderedWindows(in: content)
                    // Freeze the screen first, so the selection is made on (and cut from) a still image.
                    var frozen: [CGDirectDisplayID: Shot] = [:]
                    if Preferences.freezeScreen { frozen = await Capturer.freezeDisplays(content: content) }
                    let result = await self.selection.run(windowMode: mode == .window, candidates: candidates,
                                                          frozen: frozen)
                    switch result {
                    case .cancelled:
                        return
                    case let .area(rect, selectedScreen):
                        screen = selectedScreen
                        let id = screen.displayID
                        if let id { self.lastArea = (rect.offsetBy(dx: -screen.frame.minX, dy: -screen.frame.minY), id) }
                        if let full = id.flatMap({ frozen[$0] }), let cropped = Capturer.crop(full, to: rect, on: screen) {
                            shot = cropped
                        } else {
                            shot = try await Capturer.captureDisplay(of: screen, rect: rect, content: content)
                        }
                    case let .window(window):
                        screen = NSScreen.underMouse
                        shot = try await Capturer.captureWindow(window)
                    }
                }
                self.deliver(shot, on: screen)
            } catch {
                NSLog("Karuta: capture failed: \(error)")
                if !CGPreflightScreenCaptureAccess() { self.showPermissionAlert() }
            }
        }
    }

    /// What happens after a capture, as chosen in Settings.
    private func deliver(_ shot: Shot, on screen: NSScreen) {
        if Preferences.playSound { Sounds.shutter()?.play() }
        if Preferences.copyToClipboard { Exporter.copy(shot) }
        if Preferences.saveToFile {
            do {
                try Exporter.save(shot)
            } catch {
                NSLog("Karuta: save failed: \(error)")
            }
        }
        if Preferences.showOverlay { overlay.show(shot, on: screen) }
        if Preferences.openEditor { openEditor(shot) }
    }

    private func pin(_ shot: Shot, near frame: NSRect) {
        let window = PinWindow(shot: shot, frame: frame)
        window.onClose = { [weak self, weak window] in
            self?.pins.removeAll { $0 === window }
        }
        pins.append(window)
        window.orderFrontRegardless()
    }

    private func openEditor(_ shot: Shot) {
        let editor = EditorWindowController(shot: shot)
        editor.onClose = { [weak self, weak editor] in
            self?.editors.removeAll { $0 === editor }
        }
        editors.append(editor)
        NSApp.activate()
        editor.showWindow(nil)
    }

    private func showPermissionAlert() {
        let alert = NSAlert()
        alert.messageText = "画面収録の許可が必要です"
        alert.informativeText = "システム設定の「プライバシーとセキュリティ」>「画面とシステムオーディオ録音」で Karuta を許可してから、もう一度お試しください。"
        alert.addButton(withTitle: "設定を開く")
        alert.addButton(withTitle: "閉じる")
        NSApp.activate()
        if alert.runModal() == .alertFirstButtonReturn,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }
}
