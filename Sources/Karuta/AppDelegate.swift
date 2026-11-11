import AppKit
import ScreenCaptureKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    enum CaptureMode: Equatable {
        case allInOne, area, window, fullscreen, previousArea, selfTimer
        /// A given area (AppKit global coordinates) on a screen, from the URL scheme.
        case fixed(CGRect, NSScreen)
    }

    /// What to do with a shot: the After Capture settings, or one fixed action ("範囲を撮影してコピー" etc.).
    enum Delivery {
        case settings, copy, save, annotate, pin
    }

    var statusItem: NSStatusItem?
    let selection = SelectionController()
    let overlay = QuickOverlay()
    private var editors: [EditorWindowController] = []
    var pins: [PinWindow] = []
    /// The last area selection, relative to its display's origin (so it survives display rearrangement),
    /// for "前回の範囲を撮影".
    private var lastArea: (rect: CGRect, displayID: CGDirectDisplayID)?
    var isCapturing = false
    var settings: SettingsWindowController?
    var history: HistoryWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        setUpStatusItem()
        registerHotKeys()
        CaptureHistory.prune()
        NotificationCenter.default.addObserver(forName: Preferences.didChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.registerHotKeys()
                guard let self, self.recording == nil else { return } // the item is the stop button while recording
                self.rebuildMenu()
                self.statusItem?.isVisible = Preferences.showMenuBarIcon
            }
        }
        overlay.onEdit = { [weak self] shot, background in self?.openEditor(shot, background: background) }
        overlay.onPin = { [weak self] shot, frame in self?.pin(shot, near: frame) }
        // The bench copy doesn't put up the system prompt at launch (it would take the screen).
        if !CGPreflightScreenCaptureAccess() && !Bench.isActive {
            CGRequestScreenCaptureAccess()
        }
    }

    /// `karuta://` URLs (see URLCommand).
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            guard let command = URLCommand(url) else {
                NSLog("Karuta: unknown URL \(url.absoluteString)")
                NSSound.beep()
                continue
            }
            run(command)
        }
    }

    private func run(_ command: URLCommand) {
        switch command {
        case let .capture(mode, delivery): capture(mode, delivery: delivery)
        case let .captureRect(rect, screen, delivery): capture(.fixed(rect, screen), delivery: delivery)
        case let .allInOne(initial): capture(.allInOne, initial: initial)
        case let .pin(file):
            if let file {
                guard let shot = ImageLoader.shot(contentsOf: file) else { return NSSound.beep() }
                pin(shot, near: NSScreen.underMouse.visibleFrame)
            } else {
                perform(.pinFile)
            }
        case let .annotate(file):
            if let file {
                guard let shot = ImageLoader.shot(contentsOf: file) else { return NSSound.beep() }
                openEditor(shot)
            } else {
                perform(.openFile)
            }
        case .openClipboard: perform(.openClipboard)
        case let .addOverlay(file):
            guard let shot = ImageLoader.shot(contentsOf: file) else { return NSSound.beep() }
            overlay.show(shot, on: NSScreen.underMouse)
        case .openHistory: perform(.openHistory)
        case .restoreClosed: perform(.restoreClosed)
        case let .openSettings(page): showSettings(page)
        case let .shortcut(action): perform(action)
        case let .record(area): toggleRecording(area: area)
        case let .scroll(area, autoScroll): scrollingCapture(area: area, autoScroll: autoScroll)
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
            [.allInOne, .area, .window, .fullscreen, .previousArea, .selfTimer, .scrollingCapture, .recordScreen],
            [.openClipboard, .openFile, .pinFile, .restoreClosed, .openHistory],
            [.togglePins, .unlockPins, .closeAllPins],
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
    func registerHotKeys() {
        let hotKeys = HotKeyCenter.shared
        hotKeys.unregisterAll()
        // The bench copy (scripts/make-bench-copy.sh) runs next to the real Karuta for checks; it must not
        // take the global shortcuts away from it.
        guard !Bench.isActive else { return }
        for action in ShortcutAction.allCases {
            guard let shortcut = Preferences.shortcut(for: action) else { continue }
            hotKeys.register(keyCode: Int(shortcut.keyCode), modifiers: Int(shortcut.modifiers)) { [weak self] in
                self?.perform(action)
            }
        }
    }

    // MARK: - Actions (in AppDelegate+Actions.swift)

    // MARK: - Capture

    /// `initial` overrides All-In-One's starting area (normally the previous one).
    func capture(_ mode: CaptureMode, delivery: Delivery = .settings, initial: CGRect? = nil) {
        guard !isCapturing else { return }
        isCapturing = true
        // Before the selection overlay brings Karuta forward: the app being captured, for the file name.
        let app = NSWorkspace.shared.frontmostApplication.flatMap { $0 == .current ? nil : $0.localizedName }
        Task {
            defer { self.isCapturing = false }
            do {
                let content = try await Capturer.shareableContent()
                var shot: Shot
                let screen: NSScreen
                let frame: NSRect // where the shot was on screen (AppKit global), for pinning it in place
                var delivery = delivery
                var isWindow = false
                switch mode {
                case .fullscreen:
                    screen = NSScreen.underMouse
                    frame = screen.frame
                    shot = try await Capturer.captureDisplay(of: screen, rect: nil, content: content)
                case let .fixed(rect, fixedScreen):
                    screen = fixedScreen
                    frame = rect
                    // Like a dragged area, it becomes the previous area.
                    if let id = screen.displayID {
                        self.lastArea = (rect.offsetBy(dx: -screen.frame.minX, dy: -screen.frame.minY), id)
                    }
                    shot = try await Capturer.captureDisplay(of: screen, rect: rect, content: content)
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
                case .area, .window, .selfTimer, .allInOne:
                    var timed = mode == .selfTimer
                    let candidates = Capturer.orderedWindows(in: content)
                    // Freeze the screen first, so the selection is made on (and cut from) a still image.
                    // The self-timer captures the live screen after the countdown, so it never freezes.
                    var frozen: [CGDirectDisplayID: Shot] = [:]
                    if Preferences.freezeScreen && !timed { frozen = await Capturer.freezeDisplays(content: content) }
                    // All-In-One starts on the given area or the previous one, ready to adjust.
                    var start: CGRect?
                    if mode == .allInOne {
                        start = initial ?? self.lastArea.flatMap { last in
                            NSScreen.screens.first { $0.displayID == last.displayID }
                                .map { last.rect.offsetBy(dx: $0.frame.minX, dy: $0.frame.minY) }
                        }
                    }
                    let result = await self.selection.run(windowMode: mode == .window, candidates: candidates,
                                                          frozen: frozen, allInOne: mode == .allInOne,
                                                          initial: start)
                    if mode == .allInOne {
                        switch self.selection.action {
                        case .capture: break
                        case .copy: delivery = .copy
                        case .save: delivery = .save
                        case .annotate: delivery = .annotate
                        case .pin: delivery = .pin
                        case .timer: timed = true
                        }
                    }
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
                shot.app = app
                let kind: CaptureHistory.Kind = mode == .fullscreen ? .fullscreen : isWindow ? .window : .area
                self.deliver(shot, on: screen, frame: frame, isWindow: isWindow, kind: kind, delivery: delivery)
            } catch {
                NSLog("Karuta: capture failed: \(error)")
                if !CGPreflightScreenCaptureAccess() { self.showPermissionAlert() }
            }
        }
    }

    /// What happens after a capture, as chosen in Settings.
    func deliver(_ raw: Shot, on screen: NSScreen, frame: NSRect, isWindow: Bool, kind: CaptureHistory.Kind,
                         delivery: Delivery) {
        if Preferences.playSound { Sounds.shutter()?.play() }
        let backdrop = switch Preferences.autoBackdrop {
        case .off: false
        case .windows: isWindow
        case .all: true
        }
        // The editor gets the plain shot with the background switched on, so the backdrop stays adjustable.
        let shot = backdrop ? Backdrop.compose(raw) : raw
        CaptureHistory.add(shot, kind: kind)
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
                // Keep the shot in Quick Access so it isn't lost, then say why it wasn't saved.
                overlay.show(shot, original: backdrop ? raw : nil, on: screen)
                QuickOverlay.showSaveError(error)
            }
            return
        case .annotate:
            openEditor(raw, background: backdrop)
            return
        case .pin:
            pin(shot, near: frame)
            return
        }
        // Copy once even when both the general and the area-only setting are on.
        if Preferences.copyToClipboard || (kind == .area && Preferences.copyAreaCaptureToClipboard) {
            Exporter.copy(shot)
        }
        var saveError: Error?
        if Preferences.saveToFile {
            do {
                try Exporter.save(shot)
            } catch {
                NSLog("Karuta: save failed: \(error)")
                saveError = error
            }
        }
        // A shot that couldn't be saved stays in Quick Access even when the overlay is off.
        if Preferences.showOverlay || saveError != nil { overlay.show(shot, original: backdrop ? raw : nil, on: screen) }
        if Preferences.openEditor { openEditor(raw, background: backdrop) }
        if let saveError { QuickOverlay.showSaveError(saveError) }
    }

    func pin(_ shot: Shot, near frame: NSRect) {
        let window = PinWindow(shot: shot, frame: frame)
        window.onClose = { [weak self, weak window] in
            self?.pins.removeAll { $0 === window }
        }
        window.onEdit = { [weak self] shot in self?.openEditor(shot) }
        window.onCloseAll = { [weak self] in self?.perform(.closeAllPins) }
        pins.append(window)
        window.orderFrontRegardless()
    }

    func openEditor(_ shot: Shot, background: Bool = false) {
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

    // MARK: - Scrolling capture (the rest is in AppDelegate+ScrollCapture.swift)

    var scrollSession: ScrollCapture?

    // MARK: - Recording (the rest is in AppDelegate+Recording.swift)

    var recording: Recording?

    func showIdleStatusItem() {
        guard let item = statusItem, let button = item.button else { return }
        item.length = NSStatusItem.squareLength
        button.image = NSImage(systemSymbolName: "rectangle.dashed", accessibilityDescription: "Karuta")
        button.contentTintColor = nil
        button.imagePosition = .imageOnly
        button.title = ""
        button.toolTip = nil
        button.target = nil
        button.action = nil
        rebuildMenu()
        item.isVisible = Preferences.showMenuBarIcon
    }

    func showPermissionAlert() {
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
