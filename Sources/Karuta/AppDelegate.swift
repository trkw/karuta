import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    enum CaptureMode {
        case area, window, fullscreen, previousArea, selfTimer
    }

    /// What to do with a shot: the After Capture settings, or one fixed action ("範囲を撮影してコピー" etc.).
    enum Delivery {
        case settings, copy, save, annotate, pin
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
        overlay.onEdit = { [weak self] shot, background in self?.openEditor(shot, background: background) }
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
        item.button?.image = NSImage(systemSymbolName: "rectangle.dashed", accessibilityDescription: "Karuta")

        statusItem = item
        item.isVisible = Preferences.showMenuBarIcon
        rebuildMenu()
    }

    private func rebuildMenu() {
        let menu = NSMenu()
        let groups: [[ShortcutAction]] = [
            [.area, .window, .fullscreen, .previousArea, .selfTimer],
            [.openClipboard, .openFile, .pinFile, .restoreClosed],
        ]
        for group in groups {
            for action in group {
                let item = MenuAction(title: action.title) { [weak self] in self?.perform(action) }
                if let key = Preferences.shortcut(for: action)?.menuKeyEquivalent {
                    item.keyEquivalent = key.key
                    item.keyEquivalentModifierMask = key.mask
                }
                menu.addItem(item)
            }
            menu.addItem(.separator())
        }
        let settingsItem = NSMenuItem(title: "設定…", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Karuta を終了", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem?.menu = menu
    }

    /// Shortcuts come from Settings (default ⌘⇧3 / ⌘⇧4 / ⌘⇧5 like CleanShot; turn off the macOS ones).
    private func registerHotKeys() {
        let hotKeys = HotKeyCenter.shared
        hotKeys.unregisterAll()
        for action in ShortcutAction.allCases {
            guard let shortcut = Preferences.shortcut(for: action) else { continue }
            hotKeys.register(keyCode: Int(shortcut.keyCode), modifiers: Int(shortcut.modifiers)) { [weak self] in
                self?.perform(action)
            }
        }
    }

    // MARK: - Actions

    private func perform(_ action: ShortcutAction) {
        switch action {
        case .area: capture(.area)
        case .window: capture(.window)
        case .fullscreen: capture(.fullscreen)
        case .previousArea: capture(.previousArea)
        case .selfTimer: capture(.selfTimer)
        case .areaCopy: capture(.area, delivery: .copy)
        case .areaSave: capture(.area, delivery: .save)
        case .areaAnnotate: capture(.area, delivery: .annotate)
        case .areaPin: capture(.area, delivery: .pin)
        case .openClipboard:
            guard let shot = ImageLoader.shotFromPasteboard() else {
                NSSound.beep()
                return
            }
            openEditor(shot)
        case .openFile:
            if let shot = ImageLoader.chooseImage(prompt: "編集") { openEditor(shot) }
        case .pinFile:
            // Centred on the screen under the mouse.
            if let shot = ImageLoader.chooseImage(prompt: "ピン留め") { pin(shot, near: NSScreen.underMouse.visibleFrame) }
        case .restoreClosed:
            if !overlay.restoreClosed(on: NSScreen.underMouse) { NSSound.beep() }
        case .toggleOverlays: overlay.toggleHidden()
        case .saveAllOverlays: overlay.saveAll()
        case .closeAllOverlays: overlay.closeAll()
        }
    }

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

    private func capture(_ mode: CaptureMode, delivery: Delivery = .settings) {
        guard !isCapturing else { return }
        isCapturing = true
        Task {
            defer { self.isCapturing = false }
            do {
                let content = try await Capturer.shareableContent()
                let shot: Shot
                let screen: NSScreen
                let frame: NSRect // where the shot was on screen (AppKit global), for pinning it in place
                var delivery = delivery
                var isWindow = false
                switch mode {
                case .fullscreen:
                    screen = NSScreen.underMouse
                    frame = screen.frame
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
                    frame = rect
                    shot = try await Capturer.captureDisplay(of: screen, rect: rect, content: content)
                case .area, .window, .selfTimer:
                    let timed = mode == .selfTimer
                    let candidates = Capturer.orderedWindows(in: content)
                    // Freeze the screen first, so the selection is made on (and cut from) a still image.
                    // The self-timer captures the live screen after the countdown, so it never freezes.
                    var frozen: [CGDirectDisplayID: Shot] = [:]
                    if Preferences.freezeScreen && !timed { frozen = await Capturer.freezeDisplays(content: content) }
                    let result = await self.selection.run(windowMode: mode == .window, candidates: candidates,
                                                          frozen: frozen)
                    // Holding ⌃ while finishing the selection copies instead (CleanShot does the same).
                    if delivery == .settings && NSEvent.modifierFlags.contains(.control) { delivery = .copy }
                    switch result {
                    case .cancelled:
                        return
                    case let .area(rect, selectedScreen):
                        screen = selectedScreen
                        frame = rect
                        let id = screen.displayID
                        if let id { self.lastArea = (rect.offsetBy(dx: -screen.frame.minX, dy: -screen.frame.minY), id) }
                        if timed {
                            guard await SelfTimer.countdown(Preferences.selfTimerSeconds, over: rect) else { return }
                            // The screen has changed during the countdown (that's the point), so ask again.
                            let fresh = try await Capturer.shareableContent()
                            shot = try await Capturer.captureDisplay(of: screen, rect: rect, content: fresh)
                        } else if let full = id.flatMap({ frozen[$0] }),
                                  let cropped = Capturer.crop(full, to: rect, on: screen) {
                            shot = cropped
                        } else {
                            shot = try await Capturer.captureDisplay(of: screen, rect: rect, content: content)
                        }
                    case let .window(window):
                        screen = NSScreen.underMouse
                        frame = Geometry.appKitRect(fromCG: window.frame)
                        if timed {
                            guard await SelfTimer.countdown(Preferences.selfTimerSeconds, over: frame) else { return }
                        }
                        shot = try await Capturer.captureWindow(window)
                        isWindow = true
                    }
                }
                self.deliver(shot, on: screen, frame: frame, isWindow: isWindow, delivery: delivery)
            } catch {
                NSLog("Karuta: capture failed: \(error)")
                if !CGPreflightScreenCaptureAccess() { self.showPermissionAlert() }
            }
        }
    }

    /// What happens after a capture, as chosen in Settings.
    private func deliver(_ raw: Shot, on screen: NSScreen, frame: NSRect, isWindow: Bool, delivery: Delivery) {
        if Preferences.playSound { Sounds.shutter()?.play() }
        let backdrop = switch Preferences.autoBackdrop {
        case .off: false
        case .windows: isWindow
        case .all: true
        }
        // The editor gets the plain shot with the background switched on, so the backdrop stays adjustable.
        let shot = backdrop ? Backdrop.compose(raw) : raw
        switch delivery {
        case .settings:
            break
        case .copy:
            Exporter.copy(shot)
            return
        case .save:
            do {
                try Exporter.save(shot)
            } catch {
                NSLog("Karuta: save failed: \(error)")
                NSSound.beep()
            }
            return
        case .annotate:
            openEditor(raw, background: backdrop)
            return
        case .pin:
            pin(shot, near: frame)
            return
        }
        if Preferences.copyToClipboard { Exporter.copy(shot) }
        if Preferences.saveToFile {
            do {
                try Exporter.save(shot)
            } catch {
                NSLog("Karuta: save failed: \(error)")
            }
        }
        if Preferences.showOverlay { overlay.show(shot, original: backdrop ? raw : nil, on: screen) }
        if Preferences.openEditor { openEditor(raw, background: backdrop) }
    }

    private func pin(_ shot: Shot, near frame: NSRect) {
        let window = PinWindow(shot: shot, frame: frame)
        window.onClose = { [weak self, weak window] in
            self?.pins.removeAll { $0 === window }
        }
        pins.append(window)
        window.orderFrontRegardless()
    }

    private func openEditor(_ shot: Shot, background: Bool = false) {
        let editor = EditorWindowController(shot: shot, background: background)
        editor.onDone = { [weak self] edited in self?.overlay.show(edited, on: NSScreen.underMouse) }
        editor.onPin = { [weak self] edited, frame in self?.pin(edited, near: frame) }
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
