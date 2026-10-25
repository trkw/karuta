import AppKit
import Carbon.HIToolbox
import ServiceManagement

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    enum CaptureMode {
        case area, window, fullscreen
    }

    private var statusItem: NSStatusItem?
    private let selection = SelectionController()
    private let overlay = QuickOverlay()
    private var isCapturing = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        setUpStatusItem()
        registerHotKeys()
        if !CGPreflightScreenCaptureAccess() {
            CGRequestScreenCaptureAccess()
        }
    }

    // MARK: - Setup

    private func setUpStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = Self.menuBarImage()

        let menu = NSMenu()
        menu.addItem(menuItem("範囲を撮影", #selector(captureArea), key: "4"))
        menu.addItem(menuItem("ウィンドウを撮影", #selector(captureWindow), key: "5"))
        menu.addItem(menuItem("全画面を撮影", #selector(captureFullscreen), key: "3"))
        menu.addItem(.separator())
        let login = menuItem("ログイン時に起動", #selector(toggleLoginItem(_:)))
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Karuta を終了", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        item.menu = menu
        statusItem = item
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

    private func menuItem(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        if !key.isEmpty { item.keyEquivalentModifierMask = [.option, .shift] }
        return item
    }

    /// ⌥⇧3 全画面 / ⌥⇧4 範囲 / ⌥⇧5 ウィンドウ
    private func registerHotKeys() {
        let modifiers = optionKey | shiftKey
        let hotKeys = HotKeyCenter.shared
        hotKeys.register(keyCode: kVK_ANSI_3, modifiers: modifiers) { [weak self] in self?.capture(.fullscreen) }
        hotKeys.register(keyCode: kVK_ANSI_4, modifiers: modifiers) { [weak self] in self?.capture(.area) }
        hotKeys.register(keyCode: kVK_ANSI_5, modifiers: modifiers) { [weak self] in self?.capture(.window) }
    }

    // MARK: - Actions

    @objc private func captureArea() { capture(.area) }
    @objc private func captureWindow() { capture(.window) }
    @objc private func captureFullscreen() { capture(.fullscreen) }

    @objc private func toggleLoginItem(_ sender: NSMenuItem) {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled {
                try service.unregister()
            } else {
                try service.register()
            }
        } catch {
            NSLog("Karuta: login item toggle failed: \(error)")
        }
        sender.state = service.status == .enabled ? .on : .off
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
                case .area, .window:
                    let candidates = Capturer.orderedWindows(in: content)
                    switch await self.selection.run(windowMode: mode == .window, candidates: candidates) {
                    case .cancelled:
                        return
                    case let .area(rect, selectedScreen):
                        screen = selectedScreen
                        shot = try await Capturer.captureDisplay(of: screen, rect: rect, content: content)
                    case let .window(window):
                        screen = NSScreen.underMouse
                        shot = try await Capturer.captureWindow(window)
                    }
                }
                self.overlay.show(shot, on: screen)
            } catch {
                NSLog("Karuta: capture failed: \(error)")
                if !CGPreflightScreenCaptureAccess() { self.showPermissionAlert() }
            }
        }
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
