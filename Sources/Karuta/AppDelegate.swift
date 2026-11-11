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
    var editors: [EditorWindowController] = []
    var pins: [PinWindow] = []
    /// The last area selection, relative to its display's origin (so it survives display rearrangement),
    /// for "前回の範囲を撮影".
    var lastArea: (rect: CGRect, displayID: CGDirectDisplayID)?
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

    // MARK: - Capture (in AppDelegate+Capture.swift)

    // MARK: - Delivery (in AppDelegate+Deliver.swift)

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
